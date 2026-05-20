# Build a navigable world map from a Lich5 mapdb JSON snapshot.
#
# Outputs:
#   world_data.json   - compact layout data consumed by world_map.html
#
# Layout strategy:
#   1. Group rooms by `location` (the in-game area name).
#   2. For each area, BFS from the highest-degree room; place neighbours by
#      cardinal/diagonal direction vector. First-placement wins on conflicts.
#   3. Unreached components within an area are stacked below the main grid.
#   4. Areas are placed globally with a simple force-directed layout: edges
#      between areas pull them together, all area pairs repel, with collision
#      radii sized to each area's bounding box. Isolated areas are parked.
#   5. Room positions are translated into world space.

require "json"
require "set"

INPUT  = ARGV[0] || "C:/Users/Asus/Desktop/Lich5/data/GSIV/map-1778950731.json"
OUTPUT = ARGV[1] || File.expand_path("../world_data.json", __FILE__)

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

puts "Loading #{INPUT}..."
rooms = JSON.parse(File.read(INPUT))
puts "  #{rooms.size} rooms"

by_id = {}
rooms.each { |r| by_id[r["id"]] = r }

# Normalize location for grouping. nil / false / empty -> "_unsorted".
rooms.each do |r|
  loc = r["location"]
  loc = nil unless loc.is_a?(String)
  loc = nil if loc && loc.strip.empty?
  r["_loc"] = loc || "_unsorted"
end

groups = rooms.group_by { |r| r["_loc"] }
puts "  #{groups.size} location groups"

# For each room, compute a directional-degree score so BFS starts at a
# well-connected node (more likely to anchor the area cleanly).
deg = Hash.new(0)
rooms.each do |r|
  next unless r["wayto"].is_a?(Hash)
  r["wayto"].each_value do |cmd|
    deg[r["id"]] += 1 if DIRECTIONS.key?(cmd.to_s.strip)
  end
end

# ---------- per-area layout ----------
puts "Laying out areas..."
area_layouts = {}  # area_name => { room_id => [x, y] }

groups.each do |area_name, area_rooms|
  ids_here = area_rooms.map { |r| r["id"] }.to_set
  remaining = area_rooms.sort_by { |r| -deg[r["id"]] }.map { |r| r["id"] }

  # Pass 1: BFS each component, collect local placements with bboxes.
  components_local = []
  placed = {}
  until remaining.empty?
    start = remaining.shift
    next if placed[start]

    local = { start => [0, 0] }
    queue = [start]
    until queue.empty?
      cur = queue.shift
      cx, cy = local[cur]
      room = by_id[cur]
      next unless room && room["wayto"].is_a?(Hash)
      room["wayto"].each do |dst_id_s, cmd|
        dst_id = dst_id_s.to_i
        next unless ids_here.include?(dst_id)
        next if local.key?(dst_id)
        vec = DIRECTIONS[cmd.to_s.strip]
        next unless vec
        local[dst_id] = [cx + vec[0], cy + vec[1]]
        queue << dst_id
      end
    end

    xs = local.values.map { |xy| xy[0] }
    ys = local.values.map { |xy| xy[1] }
    bbox = { min_x: xs.min, min_y: ys.min, max_x: xs.max, max_y: ys.max,
             w: xs.max - xs.min + 1, h: ys.max - ys.min + 1 }
    components_local << [local, bbox]
    local.each_key { |id| placed[id] = true }
    remaining.reject! { |id| placed[id] }
  end

  # Rooms with NO directional edges become a trailing block of singletons.
  unplaced = area_rooms.reject { |r| placed[r["id"]] }
  if unplaced.any?
    side = Math.sqrt(unplaced.size).ceil
    local = {}
    unplaced.each_with_index do |r, i|
      local[r["id"]] = [i % side, i / side]
    end
    components_local << [local, { min_x: 0, min_y: 0,
                                   max_x: side - 1, max_y: ((unplaced.size - 1) / side),
                                   w: side, h: ((unplaced.size - 1) / side) + 1 }]
  end

  # Pass 2: shelf-pack the components into a roughly square area.
  positions = {}
  total_cells = components_local.sum { |_, b| b[:w] * b[:h] }
  target_w = [Math.sqrt(total_cells * 1.4).ceil, 8].max  # slightly wider than tall
  gap = 2

  # Sort by descending height (FFDH shelf-packing).
  sorted = components_local.sort_by { |_, b| -b[:h] }

  shelves = []  # each: { y:, used_w:, h: }
  sorted.each do |local, bbox|
    placed_on_shelf = false
    shelves.each do |sh|
      if sh[:used_w] + bbox[:w] + gap <= target_w * 1.5
        ox = sh[:used_w] - bbox[:min_x]
        oy = sh[:y] - bbox[:min_y]
        local.each { |id, (x, y)| positions[id] = [x + ox, y + oy] }
        sh[:used_w] += bbox[:w] + gap
        placed_on_shelf = true
        break
      end
    end
    next if placed_on_shelf
    # New shelf at the bottom.
    new_y = shelves.empty? ? 0 : (shelves.last[:y] + shelves.last[:h] + gap)
    ox = -bbox[:min_x]
    oy = new_y - bbox[:min_y]
    local.each { |id, (x, y)| positions[id] = [x + ox, y + oy] }
    shelves << { y: new_y, used_w: bbox[:w] + gap, h: bbox[:h] }
  end

  area_layouts[area_name] = positions
end

# ---------- area sizes / bounding boxes ----------
area_bounds = {}
area_layouts.each do |name, pos|
  xs = pos.values.map { |xy| xy[0] }
  ys = pos.values.map { |xy| xy[1] }
  area_bounds[name] = {
    min_x: xs.min, max_x: xs.max,
    min_y: ys.min, max_y: ys.max,
    w: xs.max - xs.min + 1,
    h: ys.max - ys.min + 1,
    n: pos.size,
  }
end

# ---------- inter-area constraints ----------
# Build two graphs:
#   * dir_pair_delta: for each pair of areas (A, B) connected by cardinal
#     cross-area edges, the implied delta (B_origin - A_origin) that aligns
#     the linking rooms when the road is stepped from A into B.
#   * any_pair_edges: every cross-area edge (including portals/scripts),
#     used to hang portal-only areas off a placed neighbor.
puts "Building area-graph constraints..."
CELL = 18.0
PAD  = 6     # cells of padding around an area when fallback-placing

area_names = area_layouts.keys

dir_deltas = Hash.new { |h, k| h[k] = [] }     # [a,b] sorted => list of [dx,dy]
dir_counts = Hash.new(0)                        # [a,b] sorted => count
any_pair   = Hash.new(0)                        # [a,b] sorted => count (any cmd)

# Areas that should never act as a geographic anchor. "_unsorted" is rooms
# with no `location` field — scattered transit/wilderness that would warp the
# layout if used as a hub. They still get displayed; they just don't constrain.
JUNK_AREAS = ["_unsorted", "false", ""].to_set

rooms.each do |r|
  next unless r["wayto"].is_a?(Hash)
  src_loc = r["_loc"]
  src_id  = r["id"]
  src_lpos = area_layouts[src_loc][src_id]
  r["wayto"].each do |dst_id_s, cmd|
    dst = by_id[dst_id_s.to_i]
    next unless dst
    dst_loc = dst["_loc"]
    next if dst_loc == src_loc
    pair = [src_loc, dst_loc].sort
    any_pair[pair] += 1
    vec = DIRECTIONS[cmd.to_s.strip]
    next unless vec
    # Skip directional constraints that involve a junk area on either side.
    next if JUNK_AREAS.include?(src_loc) || JUNK_AREAS.include?(dst_loc)
    dst_lpos = area_layouts[dst_loc][dst["id"]]
    next unless dst_lpos
    # origin_dst + dst_lpos = origin_src + src_lpos + vec
    # delta(src→dst) = src_lpos + vec - dst_lpos
    dx = src_lpos[0] + vec[0] - dst_lpos[0]
    dy = src_lpos[1] + vec[1] - dst_lpos[1]
    # Store as delta(pair[0] → pair[1]).
    if pair[0] == src_loc
      dir_deltas[pair] << [dx, dy]
    else
      dir_deltas[pair] << [-dx, -dy]
    end
    dir_counts[pair] += 1
  end
end
puts "  directional pair constraints: #{dir_deltas.size}"
puts "  total cross-area pairs (any kind): #{any_pair.size}"

# Average the deltas per pair so noisy or conflicting roads still produce a
# single best-fit relative position.
pair_delta = {}
dir_deltas.each do |pair, list|
  sx = sy = 0.0
  list.each { |d| sx += d[0]; sy += d[1] }
  pair_delta[pair] = [sx / list.size, sy / list.size, list.size]
end

# Adjacency: each entry is [neighbor, delta_to_neighbor_as_seen_from_self, weight].
dir_adj = Hash.new { |h, k| h[k] = [] }
pair_delta.each do |(a, b), (dx, dy, w)|
  dir_adj[a] << [b,  dx,  dy, w]
  dir_adj[b] << [a, -dx, -dy, w]
end

# Find connected components of the DIRECTIONAL graph.
visited_dir = {}
dir_components = []
area_names.each do |name|
  next if visited_dir[name]
  stack = [name]
  comp = []
  until stack.empty?
    n = stack.pop
    next if visited_dir[n]
    visited_dir[n] = true
    comp << n
    dir_adj[n].each { |nb, *| stack << nb unless visited_dir[nb] }
  end
  dir_components << comp
end
dir_components.sort_by! { |c| -c.size }
puts "  directional components: #{dir_components.size}, sizes: #{dir_components.first(5).map(&:size).inspect}"

# ---------- BFS the main directional component from a hub ----------
positions = {}
main_dir = dir_components.first || []
unless main_dir.empty?
  # Pick a hub: the area with the most directional neighbors (and ties broken
  # by being a "main town" — i.e., a populous area). Never pick a junk area.
  root = main_dir.reject { |a| JUNK_AREAS.include?(a) }.max_by { |a| [dir_adj[a].size, area_bounds[a][:n]] }
  root ||= main_dir.first
  puts "  BFS root: #{root.inspect} (#{dir_adj[root].size} dir neighbors, #{area_bounds[root][:n]} rooms)"

  positions[root] = [0.0, 0.0]
  queue = [root]
  visited_bfs = { root => true }
  until queue.empty?
    cur = queue.shift
    cx, cy = positions[cur]
    dir_adj[cur].each do |nb, dx, dy, _w|
      next if visited_bfs[nb]
      positions[nb] = [cx + dx, cy + dy]
      visited_bfs[nb] = true
      queue << nb
    end
  end

  # Relaxation: each non-root area moves toward the weighted average of
  # (neighbor + delta_from_neighbor). Resolves over-determined constraints.
  RELAX_ITERS = 80
  RELAX_ALPHA = 0.5
  RELAX_ITERS.times do
    new_positions = {}
    main_dir.each do |name|
      next if name == root
      sumx = sumy = sumw = 0.0
      dir_adj[name].each do |nb, dx, dy, w|
        next unless positions[nb]
        # delta is name → nb, so name = nb - delta
        sumx += (positions[nb][0] - dx) * w
        sumy += (positions[nb][1] - dy) * w
        sumw += w
      end
      next if sumw <= 0
      target = [sumx / sumw, sumy / sumw]
      new_positions[name] = [
        positions[name][0] + RELAX_ALPHA * (target[0] - positions[name][0]),
        positions[name][1] + RELAX_ALPHA * (target[1] - positions[name][1]),
      ]
    end
    new_positions.each { |k, v| positions[k] = v }
  end
end

main_component_set = positions.keys.to_set
puts "  placed via directional anchors: #{main_component_set.size}"

# ---------- hang portal-only areas off their connected neighbors ----------
# Areas reachable from a placed area only via non-directional edges (ship
# boardings, "go gate", scripted exits). Spread them in a ring around their
# strongest placed neighbor rather than stacking — looks like satellites.
portal_adj = Hash.new { |h, k| h[k] = [] }
any_pair.each do |(a, b), w|
  portal_adj[a] << [b, w]
  portal_adj[b] << [a, w]
end

# Track how many satellites each source has placed so we spread them around.
satellite_count = Hash.new(0)

loop do
  added = 0
  area_names.each do |name|
    next if positions.key?(name)
    # Pick the strongest already-placed neighbor.
    best = nil; best_w = 0
    portal_adj[name].each do |nb, w|
      next unless positions[nb]
      if w > best_w
        best = nb; best_w = w
      end
    end
    next unless best
    bw, bh = area_bounds[best][:w], area_bounds[best][:h]
    nw, nh = area_bounds[name][:w], area_bounds[name][:h]
    bx, by = positions[best]

    # Distribute around the source on a ring: each subsequent satellite is at
    # a different angle. The radius scales with both areas so they don't overlap.
    slot = satellite_count[best]
    satellite_count[best] += 1
    # Use golden-angle stepping so 1..12 satellites land in nicely-spread spots.
    angle = (slot * 137.508) * Math::PI / 180.0
    radius = (Math.sqrt(bw * bh) + Math.sqrt(nw * nh)) * 0.7 + PAD
    positions[name] = [
      bx + Math.cos(angle) * radius,
      by + Math.sin(angle) * radius,
    ]
    added += 1
  end
  break if added == 0
end
portal_placed = positions.keys.to_set - main_component_set
puts "  placed via portal fallback: #{portal_placed.size}"

# ---------- park totally-disconnected areas off-grid ----------
unplaced = area_names.reject { |n| positions.key?(n) }
unless unplaced.empty?
  puts "  remaining unconnected areas (parked): #{unplaced.size}"
  max_x = positions.values.map { |xy| xy[0] }.max || 0
  max_y = positions.values.map { |xy| xy[1] }.max || 0
  park_x = max_x + 200
  park_y = 0
  row_h  = 0
  unplaced.each do |name|
    b = area_bounds[name]
    positions[name] = [park_x + b[:w] / 2.0, park_y + b[:h] / 2.0]
    park_x += b[:w] + PAD * 4
    row_h = [row_h, b[:h]].max
    if park_x > max_x + 800
      park_x = max_x + 200
      park_y += row_h + PAD * 4
      row_h = 0
    end
  end
end

# Scale all area origins from cell-space to pixel-space for downstream code.
positions.each_key { |k| positions[k] = [positions[k][0] * CELL, positions[k][1] * CELL] }

# ---------- translate rooms into world space ----------
puts "Composing world coordinates..."
world_rooms = []
area_meta = []

# Assign each area a stable color from an HSL wheel.
def hsl_to_hex(h, s, l)
  s = s.to_f; l = l.to_f
  c = (1 - (2 * l - 1).abs) * s
  hp = (h.to_f / 60.0) % 6
  x = c * (1 - (hp % 2 - 1).abs)
  r, g, b = case hp.floor
            when 0 then [c, x, 0]
            when 1 then [x, c, 0]
            when 2 then [0, c, x]
            when 3 then [0, x, c]
            when 4 then [x, 0, c]
            else        [c, 0, x]
            end
  m = l - c / 2
  to8 = ->(v) { ((v + m) * 255).round.clamp(0, 255) }
  "#%02x%02x%02x" % [to8.(r), to8.(g), to8.(b)]
end

area_names.each_with_index do |name, i|
  hue = (i * 137.508) % 360  # golden-angle hue spread
  color = hsl_to_hex(hue, 0.55, 0.55)
  b = area_bounds[name]
  # positions[name] is now the world-pixel origin of this area's local (0,0).
  ox, oy = positions[name]

  local_cx = (b[:min_x] + b[:max_x]) / 2.0
  local_cy = (b[:min_y] + b[:max_y]) / 2.0
  world_cx = ox + local_cx * CELL
  world_cy = oy + local_cy * CELL

  area_layouts[name].each do |id, (lx, ly)|
    wx = ox + lx * CELL
    wy = oy + ly * CELL
    r = by_id[id]
    title = (r["title"] || []).first.to_s.gsub(/^\[|\]$/, "")
    world_rooms << {
      "id" => id,
      "x"  => wx.round(2),
      "y"  => wy.round(2),
      "a"  => i,
      "t"  => title,
    }
  end

  area_meta << {
    "name" => name,
    "color" => color,
    "n" => b[:n],
    "cx" => world_cx.round(2),
    "cy" => world_cy.round(2),
    "w" => (b[:w] * CELL).round(2),
    "h" => (b[:h] * CELL).round(2),
    # main=true: area has a meaningful position (anchored OR portal-attached).
    # main=false: parked off-grid because nothing connects to it.
    "main" => main_component_set.include?(name) || portal_placed.include?(name),
    "anchored" => main_component_set.include?(name),
  }
end

# ---------- edge list ----------
# Keep only the simple directional / portal edges that the layout actually
# represented; record each edge once (sorted endpoints).
puts "Collecting edges..."
edges = []
seen_edges = {}
rooms.each do |r|
  next unless r["wayto"].is_a?(Hash)
  src_id = r["id"]
  r["wayto"].each do |dst_id_s, cmd|
    dst_id = dst_id_s.to_i
    next unless by_id[dst_id]
    key = src_id < dst_id ? "#{src_id}-#{dst_id}" : "#{dst_id}-#{src_id}"
    next if seen_edges[key]
    seen_edges[key] = true
    cmd_s = cmd.to_s.strip
    type = if DIRECTIONS.key?(cmd_s) then 0           # cardinal/diagonal
           elsif cmd_s == "up" || cmd_s == "down" then 1
           elsif cmd_s =~ /^go\s+/ then 2             # portal
           elsif cmd_s.length < 30 then 3             # short cmd
           else 4                                     # script
           end
    edges << [src_id, dst_id, type]
  end
end
puts "  #{edges.size} unique edges"

# ---------- write output ----------
out = {
  "meta" => {
    "source" => INPUT,
    "generated_at" => Time.now.utc.iso8601,
    "cell" => CELL,
    "room_count" => world_rooms.size,
    "area_count" => area_meta.size,
    "edge_count" => edges.size,
  },
  "areas" => area_meta,
  "rooms" => world_rooms,
  "edges" => edges,
}

File.write(OUTPUT, JSON.generate(out))
puts "Wrote #{OUTPUT} (#{(File.size(OUTPUT) / 1024.0 / 1024.0).round(2)} MB)"
