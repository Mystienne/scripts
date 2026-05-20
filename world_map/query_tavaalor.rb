require "json"
require "set"

data = JSON.parse(File.read("C:/Users/Asus/Desktop/Lich5/data/GSIV/map-1778950731.json"))
by_id = {}
data.each { |r| by_id[r["id"]] = r }

# Anything whose location mentions vaalor or sylvarraend counts as "inside the Vaalor region".
focus_locs = data.map { |r| r["location"] }.compact.uniq.select do |l|
  l.is_a?(String) && (l =~ /vaalor/i || l =~ /sylvarraend/i)
end
puts "Focus (Ta'Vaalor + nested):"
focus_locs.each { |l| puts "  - #{l}" }

seed = data.select { |r| focus_locs.include?(r["location"]) }.map { |r| r["id"] }.to_set
puts "\nRooms inside focus: #{seed.size}"

# Walk outward one step to find every area we can reach from inside.
direct = Hash.new { |h, k| h[k] = [] }
data.each do |r|
  next unless seed.include?(r["id"])
  next unless r["wayto"].is_a?(Hash)
  src_title = (r["title"] || []).first.to_s
  r["wayto"].each do |dst_id_s, cmd|
    dst = by_id[dst_id_s.to_i]
    next unless dst
    next if focus_locs.include?(dst["location"])
    next unless dst["location"].is_a?(String) && !dst["location"].empty?
    dst_title = (dst["title"] || []).first.to_s
    direct[dst["location"]] << [src_title, dst_title, cmd.to_s[0, 60]]
  end
end

puts "\n=== AREAS REACHABLE IN ONE STEP FROM VAALOR ==="
direct.sort_by { |_, v| -v.size }.each do |loc, links|
  puts "\n[#{loc}]  (#{links.size} link)"
  links.first(3).each do |from, to, cmd|
    puts "    from \"#{from}\" -> \"#{to}\"   via #{cmd.inspect}"
  end
  puts "    ... +#{links.size - 3} more" if links.size > 3
end

# Walk one MORE step out from those 1-hop neighbors so we see "2 hops away".
# This catches hunting grounds that you reach by stepping through a transit/wilds area.
hop1_room_ids = Set.new
data.each do |r|
  next unless seed.include?(r["id"])
  next unless r["wayto"].is_a?(Hash)
  r["wayto"].each_key do |dst_id_s|
    dst = by_id[dst_id_s.to_i]
    next unless dst
    next if focus_locs.include?(dst["location"])
    hop1_room_ids << dst["id"]
  end
end

# Track the area each hop-1 room belongs to so the 2-hop list links them in.
hop2 = Hash.new { |h, k| h[k] = [] }
hop1_room_ids.each do |id|
  r = by_id[id]
  next unless r && r["wayto"].is_a?(Hash)
  r["wayto"].each do |dst_id_s, cmd|
    dst = by_id[dst_id_s.to_i]
    next unless dst
    next if focus_locs.include?(dst["location"])
    next if direct.key?(dst["location"])  # already a 1-hop area
    next unless dst["location"].is_a?(String) && !dst["location"].empty?
    hop2[dst["location"]] << [r["location"], (dst["title"] || []).first.to_s, cmd.to_s[0, 60]]
  end
end

puts "\n=== AREAS REACHABLE IN TWO STEPS ==="
hop2.sort_by { |_, v| -v.size }.first(20).each do |loc, links|
  via = links.map { |l| l[0] }.uniq.first(2).join(", ")
  puts "\n[#{loc}]  (#{links.size} link, via #{via})"
end
