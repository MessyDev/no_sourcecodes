-- this module literally just holds 3 strings.
-- why is it a whole module? because multiple scripts are using it
local DTN = {}

-- the sacred key
DTN.GhostIndexKey = "GhostIndex1"

-- counts how many ghosts we've stuffed into the datastore
DTN.GhostCounterKey = "GhostCounter1"

-- the datastore name that holds every player's body movement
DTN.MovementStore = "FullBodyMovements1"

return DTN
