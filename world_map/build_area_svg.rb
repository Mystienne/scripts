# Render a Tsoran-style SVG map for one Lich5 mapdb area.
#
#   ruby build_area_svg.rb "Old Ta'Faendryl"
#
# Output: area_<slug>.svg in this directory, opens in any browser.
#
# Layout: same per-area BFS we use for the world map — cardinal/diagonal
# direction strings (north, southeast, ...) drive integer (x, y) placements
# for each room. Sub-areas are inferred from the room title prefix (e.g.
# "Aqueduct, Pillared Hall" → "Aqueduct"). Disconnected components in the
# same area are shelf-packed below the main grid.

require "json"
require "set"

INPUT = ENV["MAPDB"] || "C:/Users/Asus/Desktop/Lich5/data/GSIV/map-1778950731.json"
AREA  = ARGV[0] || "Old Ta'Faendryl"

slug = AREA.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/(^_|_$)/, "")
OUT = File.expand_path("../area_#{slug}.svg", __FILE__)

DIRECTIONS = {
  "north"     => [0, -1],
  "south"     => [0,  1],
  "east"      => [1,  0],
  "west"      => [-1, 0],
  "northeast" => [1, -1],
  "northwest" => [-1, -1],
  "southeast" => [1,  1],
  "southwest" => [-1, 1],
}

# All 8 adjacent cells, used when an exit has no cardinal direction.
ADJ_PREF = [[0, -1], [0, 1], [1, 0], [-1, 0],
            [1, -1], [-1, -1], [1, 1], [-1, 1]]

# Hint heuristics: "climb up", "go ladder up" etc. prefer pointing north;
# "climb down", "descend" prefer south.
def dir_hint(cmd)
  c = cmd.downcase
  return [[0, -1], [-1, -1], [1, -1]] if c =~ /\b(up|ascend|climb up)\b/
  return [[0,  1], [-1,  1], [1,  1]] if c =~ /\b(down|descend|climb down)\b/
  []
end

# Pick the first adjacent slot at (cx,cy) that isn't already used.
def free_slot(cx, cy, occupied, hints)
  ordered = (hints + ADJ_PREF).uniq
  ordered.each do |dx, dy|
    cand = [cx + dx, cy + dy]
    return cand unless occupied.key?(cand)
  end
  nil
end

puts "Loading #{INPUT}..."
rooms = JSON.parse(File.read(INPUT))
by_id = {}
rooms.each { |r| by_id[r["id"]] = r }

area_rooms = rooms.select { |r| r["location"] == AREA }
abort "No rooms in area #{AREA.inspect}" if area_rooms.empty?
ids = area_rooms.map { |r| r["id"] }.to_set
puts "  #{area_rooms.size} rooms in #{AREA.inspect}"

# ---------- per-area BFS layout ----------
deg = Hash.new(0)
area_rooms.each do |r|
  next unless r["wayto"].is_a?(Hash)
  r["wayto"].each_value do |cmd|
    deg[r["id"]] += 1 if DIRECTIONS.key?(cmd.to_s.strip)
  end
end

remaining = area_rooms.sort_by { |r| -deg[r["id"]] }.map { |r| r["id"] }
components = []
placed = {}

until remaining.empty?
  start = remaining.shift
  next if placed[start]
  local = { start => [0, 0] }
  occupied = { [0, 0] => start }
  queue = [start]

  # Cardinal-only BFS: those are the rooms where the data tells us the exact
  # direction. Every other connection (climb / go X / out / up / down) is
  # handled later as a glue between components.
  until queue.empty?
    cur = queue.shift
    cx, cy = local[cur]
    room = by_id[cur]
    next unless room && room["wayto"].is_a?(Hash)
    room["wayto"].each do |dst_id_s, cmd|
      dst_id = dst_id_s.to_i
      next unless ids.include?(dst_id)
      next if local.key?(dst_id)
      vec = DIRECTIONS[cmd.to_s.strip]
      next unless vec
      pos = [cx + vec[0], cy + vec[1]]
      next if occupied.key?(pos)  # cardinal conflicts: first wins
      local[dst_id] = pos
      occupied[pos] = dst_id
      queue << dst_id
    end
  end

  components << { local: local, ids: local.keys.to_set }
  local.each_key { |id| placed[id] = true }
  remaining.reject! { |id| placed[id] }
end

# Rooms with no cardinal edges at all become singleton components.
area_rooms.reject { |r| placed[r["id"]] }.each do |r|
  components << { local: { r["id"] => [0, 0] }, ids: Set.new([r["id"]]) }
  placed[r["id"]] = true
end

# ---------- glue components via non-cardinal cross-component edges ----------
# For each non-cardinal exit, if its src and dst rooms are in different
# components, record a link we can use to place one component adjacent to
# the other.
comp_of = {}
components.each_with_index do |c, i|
  c[:ids].each { |id| comp_of[id] = i }
end

inter_links = []  # [src_comp, dst_comp, src_id, dst_id, cmd]
area_rooms.each do |r|
  next unless r["wayto"].is_a?(Hash)
  src_id = r["id"]
  r["wayto"].each do |dst_id_s, cmd|
    dst_id = dst_id_s.to_i
    next unless ids.include?(dst_id)
    next if DIRECTIONS.key?(cmd.to_s.strip)  # cardinal already inside a component
    src_c = comp_of[src_id]; dst_c = comp_of[dst_id]
    next if src_c == dst_c
    inter_links << [src_c, dst_c, src_id, dst_id, cmd.to_s.strip]
  end
end

# BFS the component graph from the biggest component. For each unplaced
# neighbour, position it so its linking room lands in a free adjacent cell
# next to the source room — trying all 8 directions, then larger rings if
# the whole component would collide.
positions = {}     # room_id => [wx, wy]
world_occupied = {} # [wx, wy] => room_id
comp_origin = {}   # comp_idx => [ox, oy]

largest_idx = components.each_with_index.max_by { |c, _| c[:ids].size }[1]
def place_component(c_idx, origin, components, world_occupied, positions, comp_origin)
  comp_origin[c_idx] = origin
  components[c_idx][:local].each do |id, (lx, ly)|
    wx = lx + origin[0]; wy = ly + origin[1]
    positions[id] = [wx, wy]
    world_occupied[[wx, wy]] = id
  end
end

place_component(largest_idx, [0, 0], components, world_occupied, positions, comp_origin)

queue = [largest_idx]
visited = { largest_idx => true }
ring_offsets = []
(1..6).each do |r|
  (-r..r).each do |dx|
    (-r..r).each do |dy|
      next if dx.abs != r && dy.abs != r
      ring_offsets << [dx, dy]
    end
  end
end

until queue.empty?
  cur = queue.shift
  inter_links.each do |src_c, dst_c, src_id, dst_id, _cmd|
    next unless src_c == cur || dst_c == cur
    nb_idx = src_c == cur ? dst_c : src_c
    next if visited[nb_idx]

    # Identify the linking room in each side.
    cur_link_id, nb_link_id =
      components[cur][:ids].include?(src_id) ? [src_id, dst_id] : [dst_id, src_id]

    src_world = positions[cur_link_id]
    nb_link_local = components[nb_idx][:local][nb_link_id]

    placed_this = false
    ring_offsets.each do |dx, dy|
      target = [src_world[0] + dx, src_world[1] + dy]
      next if world_occupied.key?(target)
      nb_origin = [target[0] - nb_link_local[0], target[1] - nb_link_local[1]]
      collision = components[nb_idx][:local].any? do |_, (lx, ly)|
        world_occupied.key?([lx + nb_origin[0], ly + nb_origin[1]])
      end
      next if collision
      place_component(nb_idx, nb_origin, components, world_occupied, positions, comp_origin)
      visited[nb_idx] = true
      queue << nb_idx
      placed_this = true
      break
    end
    # If still couldn't fit, leave for tail shelf-pack at the end.
  end
end

# Anything still unplaced (couldn't fit anywhere reasonable, or had no
# connections at all): shelf-pack at the bottom in a tidy row.
leftover = components.each_with_index.reject { |_, i| visited[i] }
unless leftover.empty?
  max_y = world_occupied.empty? ? 0 : world_occupied.keys.map { |xy| xy[1] }.max
  shelf_y = max_y + 4
  shelf_x = 0
  leftover.each do |comp, idx|
    bx = comp[:local].values.map { |xy| xy[0] }.min
    by = comp[:local].values.map { |xy| xy[1] }.min
    place_component(idx, [shelf_x - bx, shelf_y - by],
                    components, world_occupied, positions, comp_origin)
    shelf_x += (comp[:local].values.map { |xy| xy[0] }.max - bx) + 3
  end
end

# ---------- sub-area grouping by title prefix ----------
# e.g. "Aqueduct, Pillared Hall" → "Aqueduct". Prefix is whatever sits before
# the first comma in the title (after stripping outer brackets). Sub-areas
# that only have one room are dropped (not worth labelling).
sub_for = {}
area_rooms.each do |r|
  title = (r["title"] || []).first.to_s.gsub(/^\[|\]$/, "")
  prefix = title.split(/,\s*/).first.to_s.strip
  sub_for[r["id"]] = prefix
end
sub_counts = Hash.new(0)
sub_for.each_value { |p| sub_counts[p] += 1 }
sub_for.each { |id, p| sub_for[id] = nil if sub_counts[p] < 3 }

# Sub-area centroids and bounding boxes for labels.
sub_meta = {}
sub_for.each do |id, prefix|
  next unless prefix
  pos = positions[id]
  s = sub_meta[prefix] ||= { ids: [], xs: [], ys: [] }
  s[:ids] << id
  s[:xs] << pos[0]
  s[:ys] << pos[1]
end
sub_meta.each do |name, s|
  s[:cx] = s[:xs].sum.to_f / s[:xs].size
  s[:cy] = s[:ys].sum.to_f / s[:ys].size
  s[:min_x] = s[:xs].min; s[:max_x] = s[:xs].max
  s[:min_y] = s[:ys].min; s[:max_y] = s[:ys].max
end

# ---------- SVG render ----------
CELL = 28        # px per cell
ROOM = 9         # room square side in px
MARGIN = 60
TITLE_H = 70

min_x = positions.values.map { |p| p[0] }.min
min_y = positions.values.map { |p| p[1] }.min
max_x = positions.values.map { |p| p[0] }.max
max_y = positions.values.map { |p| p[1] }.max
ox = MARGIN - min_x * CELL
oy = MARGIN + TITLE_H - min_y * CELL
w  = (max_x - min_x) * CELL + MARGIN * 2
h  = (max_y - min_y) * CELL + MARGIN * 2 + TITLE_H

def esc(s); s.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;"); end

svg = []
svg << %(<?xml version="1.0" encoding="UTF-8"?>)
svg << %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{w} #{h}" font-family="Georgia, 'Times New Roman', serif">)
# parchment background
svg << %(<defs>
  <linearGradient id="parchment" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0%" stop-color="#f6efd9"/>
    <stop offset="100%" stop-color="#ece1bd"/>
  </linearGradient>
</defs>)
svg << %(<rect width="100%" height="100%" fill="url(#parchment)"/>)

# Title block
svg << %(<text x="#{w / 2}" y="40" text-anchor="middle" font-size="28" font-style="italic" fill="#1a1a1a">#{esc(AREA)}</text>)
svg << %(<text x="#{w / 2}" y="60" text-anchor="middle" font-size="11" fill="#555">rendered from Lich5 mapdb &#183; #{area_rooms.size} rooms</text>)

# Compass rose top-right
cx_c = w - 50; cy_c = 100; r_c = 22
svg << %(<g stroke="#333" fill="none" stroke-width="1">)
svg << %(<circle cx="#{cx_c}" cy="#{cy_c}" r="#{r_c}"/>)
svg << %(<line x1="#{cx_c}" y1="#{cy_c - r_c}" x2="#{cx_c}" y2="#{cy_c + r_c}"/>)
svg << %(<line x1="#{cx_c - r_c}" y1="#{cy_c}" x2="#{cx_c + r_c}" y2="#{cy_c}"/>)
svg << %(</g>)
svg << %(<text x="#{cx_c}" y="#{cy_c - r_c - 4}" text-anchor="middle" font-size="11" fill="#333">N</text>)
svg << %(<text x="#{cx_c}" y="#{cy_c + r_c + 12}" text-anchor="middle" font-size="11" fill="#333">S</text>)
svg << %(<text x="#{cx_c + r_c + 8}" y="#{cy_c + 4}" font-size="11" fill="#333">E</text>)
svg << %(<text x="#{cx_c - r_c - 14}" y="#{cy_c + 4}" font-size="11" fill="#333">W</text>)

# Sub-area background shading (soft pastel tints) + labels.
sub_palette = %w[#dfeed7 #ddebf0 #f1e0d6 #ece3da #dde6dc #ebd9e0 #e6e0c8 #dadeeb]
sub_meta.keys.sort.each_with_index do |name, i|
  s = sub_meta[name]
  x1 = ox + s[:min_x] * CELL - ROOM
  y1 = oy + s[:min_y] * CELL - ROOM
  x2 = ox + s[:max_x] * CELL + ROOM
  y2 = oy + s[:max_y] * CELL + ROOM
  color = sub_palette[i % sub_palette.size]
  svg << %(<rect x="#{x1 - 4}" y="#{y1 - 4}" width="#{x2 - x1 + 8}" height="#{y2 - y1 + 8}" rx="6" fill="#{color}" fill-opacity="0.6" stroke="#bca97a" stroke-dasharray="3,3" stroke-width="0.7"/>)
end

# ---------- edges ----------
# Collect each edge once (sorted endpoints) so we don't double-draw.
drawn = {}
edge_lines = []
edge_labels = []

area_rooms.each do |r|
  next unless r["wayto"].is_a?(Hash)
  src_id = r["id"]
  sx, sy = positions[src_id]
  r["wayto"].each do |dst_id_s, cmd|
    dst_id = dst_id_s.to_i
    next unless ids.include?(dst_id)
    next unless positions[dst_id]
    key = [src_id, dst_id].min.to_s + "-" + [src_id, dst_id].max.to_s
    next if drawn[key]
    drawn[key] = true
    cmd_s = cmd.to_s.strip
    dx, dy = positions[dst_id]
    x1 = ox + sx * CELL; y1 = oy + sy * CELL
    x2 = ox + dx * CELL; y2 = oy + dy * CELL
    edge_lines << [x1, y1, x2, y2, :solid]
    # Label any exit that isn't a plain cardinal direction.
    unless DIRECTIONS.key?(cmd_s)
      mx = (x1 + x2) / 2.0; my = (y1 + y2) / 2.0
      label = cmd_s.length > 16 ? cmd_s[0, 14] + "…" : cmd_s
      edge_labels << [mx, my, label]
    end
  end
end

# Lines first, so room boxes paint over them.
svg << %(<g stroke="#3a2f1c" stroke-width="0.9" fill="none">)
edge_lines.each do |x1, y1, x2, y2, style|
  da = style == :dashed ? %( stroke-dasharray="3,3") : ""
  svg << %(<line x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}"#{da}/>)
end
svg << %(</g>)

# Portal labels.
edge_labels.each do |mx, my, label|
  svg << %(<text x="#{mx}" y="#{my - 2}" text-anchor="middle" font-size="8" fill="#5b4724" font-family="sans-serif">#{esc(label)}</text>)
end

# ---------- room boxes ----------
svg << %(<g fill="#fdfaf0" stroke="#1f1a10" stroke-width="0.9">)
positions.each do |id, (x, y)|
  cx = ox + x * CELL - ROOM / 2.0
  cy = oy + y * CELL - ROOM / 2.0
  title = (by_id[id]["title"] || []).first.to_s.gsub(/^\[|\]$/, "")
  svg << %(<rect x="#{cx}" y="#{cy}" width="#{ROOM}" height="#{ROOM}"><title>#{esc(title)} (##{id})</title></rect>)
end
svg << %(</g>)


# Sub-area labels — painted on top so they're readable.
sub_meta.keys.sort.each do |name|
  s = sub_meta[name]
  lx = ox + s[:cx] * CELL
  ly = oy + s[:min_y] * CELL - ROOM - 6
  svg << %(<text x="#{lx}" y="#{ly}" text-anchor="middle" font-size="13" font-style="italic" font-weight="bold" fill="#3a2c10">#{esc(name)}</text>)
end

svg << "</svg>"
svg_body = svg.join("\n")

File.write(OUT, svg_body)
puts "Wrote #{OUT} (#{(File.size(OUT) / 1024.0).round(1)} KB)"

# Also produce an HTML wrapper so the SVG gets real pan/zoom in any browser
# (raw .svg files don't zoom on wheel — you only get the page's zoom).
HTML_OUT = OUT.sub(/\.svg\z/, ".html")
html = <<~HTML
  <!DOCTYPE html>
  <html lang="en"><head><meta charset="utf-8">
  <title>#{esc(AREA)} - mapdb render</title>
  <style>
    html, body { margin: 0; padding: 0; height: 100%; background: #2a261e; overflow: hidden;
                  font-family: Georgia, serif; color: #ddd; }
    #stage { position: absolute; inset: 0; cursor: grab; }
    #stage:active { cursor: grabbing; }
    #stage svg { width: 100%; height: 100%; display: block; }
    #hint { position: absolute; top: 8px; right: 12px; font-size: 11px; color: #aaa;
            background: rgba(0,0,0,0.4); padding: 4px 8px; border-radius: 3px; pointer-events: none; }
    #tip { position: absolute; pointer-events: none; background: rgba(20,15,5,0.95);
           border: 1px solid #6b5a30; padding: 4px 8px; font-size: 12px; border-radius: 3px;
           color: #f0e8c8; display: none; max-width: 320px; }
  </style></head><body>
  <div id="stage">#{svg_body.sub(/<\?xml[^>]*\?>\s*/, "")}</div>
  <div id="hint">drag to pan &middot; scroll to zoom</div>
  <div id="tip"></div>
  <script>
  (function() {
    const stage = document.getElementById('stage');
    const svg = stage.querySelector('svg');
    const tip = document.getElementById('tip');
    const vb = svg.viewBox.baseVal;
    const orig = { x: vb.x, y: vb.y, w: vb.width, h: vb.height };
    function setVB(x, y, w, h) { svg.setAttribute('viewBox', x + ' ' + y + ' ' + w + ' ' + h); vb.x=x; vb.y=y; vb.width=w; vb.height=h; }
    let dragging = false, lastX = 0, lastY = 0;
    stage.addEventListener('mousedown', e => { dragging = true; lastX = e.clientX; lastY = e.clientY; });
    window.addEventListener('mouseup', () => { dragging = false; });
    stage.addEventListener('mousemove', e => {
      if (dragging) {
        const rect = svg.getBoundingClientRect();
        const sx = vb.width / rect.width, sy = vb.height / rect.height;
        setVB(vb.x - (e.clientX - lastX) * sx, vb.y - (e.clientY - lastY) * sy, vb.width, vb.height);
        lastX = e.clientX; lastY = e.clientY;
        tip.style.display = 'none';
      } else {
        const t = e.target.closest('rect[width="9"]');
        if (t) {
          const ttl = t.querySelector('title');
          if (ttl) {
            tip.textContent = ttl.textContent;
            tip.style.display = 'block';
            tip.style.left = (e.clientX + 12) + 'px';
            tip.style.top  = (e.clientY + 12) + 'px';
          }
        } else { tip.style.display = 'none'; }
      }
    });
    stage.addEventListener('wheel', e => {
      e.preventDefault();
      const factor = Math.pow(1.0015, -e.deltaY);
      const rect = svg.getBoundingClientRect();
      // mouse position in viewBox coords
      const mx = vb.x + (e.clientX - rect.left) * (vb.width / rect.width);
      const my = vb.y + (e.clientY - rect.top)  * (vb.height / rect.height);
      const nw = vb.width / factor, nh = vb.height / factor;
      setVB(mx - (mx - vb.x) / factor, my - (my - vb.y) / factor, nw, nh);
      tip.style.display = 'none';
    }, { passive: false });
    window.addEventListener('keydown', e => {
      if (e.key === '0' || e.key === 'r' || e.key === 'R') { setVB(orig.x, orig.y, orig.w, orig.h); }
    });
  })();
  </script>
  </body></html>
HTML
File.write(HTML_OUT, html)
puts "Wrote #{HTML_OUT} (#{(File.size(HTML_OUT) / 1024.0).round(1)} KB)"
puts ""
puts "Open the .html for pan/zoom in browser:"
puts "  #{HTML_OUT}"
