# Bundle world_data.json into a single self-contained world_map.html so that
# the file works when opened directly off disk (file:// blocks fetch).

require "json"

DATA = File.expand_path("../world_data.json", __FILE__)
TPL  = File.expand_path("../viewer_template.html", __FILE__)
OUT  = File.expand_path("../world_map.html", __FILE__)

data_str = File.read(DATA)
template = File.read(TPL)

# Use a placeholder rather than gsub to dodge backslash interpolation issues.
needle = "__WORLD_DATA_PLACEHOLDER__"
unless template.include?(needle)
  abort "viewer_template.html is missing #{needle}"
end

i = template.index(needle)
html = template[0...i] + data_str + template[(i + needle.size)..]

File.write(OUT, html)
puts "Wrote #{OUT} (#{(File.size(OUT) / 1024.0 / 1024.0).round(2)} MB)"
