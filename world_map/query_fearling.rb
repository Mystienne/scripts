require "json"

data = JSON.parse(File.read("C:/Users/Asus/Desktop/Lich5/data/GSIV/map-1778950731.json"))

hits = []
data.each do |r|
  title = (r["title"] || []).join(" ")
  desc  = (r["description"] || []).join(" ")
  if title =~ /fearling/i || desc =~ /fearling/i
    hits << r
  end
end

puts "Rooms whose title or description mentions 'fearling': #{hits.size}"
by_loc = hits.group_by { |r| r["location"] }
by_loc.sort_by { |_, v| -v.size }.each do |loc, rooms|
  puts "\n[#{loc || "(unsorted)"}]  #{rooms.size} room(s)"
  rooms.first(3).each do |r|
    title = (r["title"] || []).first.to_s
    desc  = (r["description"] || []).first.to_s
    # show the snippet of the description that mentions fearling
    snippet = desc[/.{0,60}fearling.{0,60}/i] || ""
    puts "  ##{r["id"]}  #{title}"
    puts "      \"...#{snippet}...\"" unless snippet.empty?
  end
  puts "  ... +#{rooms.size - 3} more rooms" if rooms.size > 3
end
