-- Disenchant bands shared by yield hints, skill gates, and value estimates.
-- Each row is: maximum item level, required skill, display text, material IDs.
DisenchanterData = DisenchanterData or {}

local tbc = {
  [2] = {
    {15, 1,   "Strange Dust / Lesser Magic Essence",                         {10940,10938}},
    {20, 1,   "Strange Dust / Greater Magic Essence / Small Glimmering Shard",{10940,10939,10978}},
    {25, 25,  "Strange Dust / Lesser Astral Essence / Small Glimmering Shard",{10940,10998,10978}},
    {30, 50,  "Soul Dust / Greater Astral Essence / Large Glimmering Shard",  {11083,11082,11084}},
    {35, 75,  "Soul Dust / Lesser Mystic Essence / Small Glowing Shard",      {11083,11134,11138}},
    {40, 100, "Vision Dust / Greater Mystic Essence / Large Glowing Shard",   {11137,11135,11139}},
    {45, 125, "Vision Dust / Lesser Nether Essence / Small Radiant Shard",    {11137,11174,11177}},
    {50, 150, "Dream Dust / Greater Nether Essence / Large Radiant Shard",    {11176,11175,11178}},
    {55, 175, "Dream Dust / Lesser Eternal Essence / Small Brilliant Shard",  {11176,16202,14343}},
    {60, 200, "Illusion Dust / Greater Eternal Essence / Large Brilliant Shard",{16204,16203,14344}},
    {65, 225, "Arcane Dust / Lesser Planar Essence / Small Prismatic Shard",  {22445,22447,22448}},
    {99, 275, "Arcane Dust / Greater Planar Essence / Small Prismatic Shard", {22445,22446,22448}},
    {200,325, "Arcane Dust / Small Prismatic Shard",                          {22445,nil,22448}},
  },
  [3] = {
    {25,1,"Small Glimmering Shard",{10978}}, {30,50,"Large Glimmering Shard",{11084}},
    {35,75,"Small Glowing Shard",{11138}}, {40,100,"Large Glowing Shard",{11139}},
    {45,125,"Small Radiant Shard",{11177}}, {50,150,"Large Radiant Shard",{11178}},
    {55,175,"Small Brilliant Shard",{14343}},
    {60,200,"Large Brilliant Shard (rarely Nexus Crystal)",{14344}},
    {65,225,"Small Prismatic Shard",{22448}}, {99,275,"Large Prismatic Shard",{22449}},
    {200,325,"Large Prismatic Shard (rarely Void Crystal)",{22449}},
  },
  [4] = {
    {45,225,"Small Brilliant Shard",{14343}}, {50,225,"Large Brilliant Shard",{14344}},
    {60,225,"Nexus Crystal",{20725}}, {95,300,"Void Crystal",{22450}},
    {200,375,"Void Crystal",{22450}},
  },
}

local era = {
  [2] = {
    {15,1,"Strange Dust / Lesser Magic Essence",{10940,10938}},
    {20,1,"Strange Dust / Greater Magic Essence / Small Glimmering Shard",{10940,10939,10978}},
    {25,1,"Strange Dust / Lesser Astral Essence / Small Glimmering Shard",{10940,10998,10978}},
    {30,1,"Soul Dust / Greater Astral Essence / Large Glimmering Shard",{11083,11082,11084}},
    {35,1,"Soul Dust / Lesser Mystic Essence / Small Glowing Shard",{11083,11134,11138}},
    {40,1,"Vision Dust / Greater Mystic Essence / Large Glowing Shard",{11137,11135,11139}},
    {45,1,"Vision Dust / Lesser Nether Essence / Small Radiant Shard",{11137,11174,11177}},
    {50,1,"Dream Dust / Greater Nether Essence / Large Radiant Shard",{11176,11175,11178}},
    {55,1,"Dream Dust / Lesser Eternal Essence / Small Brilliant Shard",{11176,16202,14343}},
    {200,1,"Illusion Dust / Greater Eternal Essence / Large Brilliant Shard",{16204,16203,14344}},
  },
  [3] = {
    {25,1,"Small Glimmering Shard",{10978}}, {30,1,"Large Glimmering Shard",{11084}},
    {35,1,"Small Glowing Shard",{11138}}, {40,1,"Large Glowing Shard",{11139}},
    {45,1,"Small Radiant Shard",{11177}}, {50,1,"Large Radiant Shard",{11178}},
    {55,1,"Small Brilliant Shard",{14343}},
    {200,1,"Large Brilliant Shard (rarely Nexus Crystal)",{14344}},
  },
  [4] = {
    {45,1,"Small Brilliant Shard",{14343}}, {50,1,"Large Brilliant Shard",{14344}},
    {200,1,"Nexus Crystal",{20725}},
  },
}

DisenchanterData.bands = WOW_PROJECT_ID == (WOW_PROJECT_CLASSIC or 2) and era or tbc
