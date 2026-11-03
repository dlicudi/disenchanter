local path = assert(arg[1], "data module path required")

local function load(projectID)
  WOW_PROJECT_CLASSIC, WOW_PROJECT_ID = 2, projectID
  DisenchanterData = nil
  dofile(path)
  return DisenchanterData.bands
end

local era = load(2)
assert(era[2][#era[2]][2] == 1)
assert(era[2][#era[2]][4][1] == 16204)
assert(era[4][#era[4]][4][1] == 20725)

local tbc = load(5)
assert(tbc[2][#tbc[2]][2] == 325)
assert(tbc[2][#tbc[2]][4][1] == 22445)
assert(tbc[4][#tbc[4]][4][1] == 22450)

print("disenchant data checks OK")
