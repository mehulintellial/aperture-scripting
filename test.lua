local gerber = require 'gerber'

local data = assert(gerber.parse('example2.ger'))

assert(#data.layers == 3)

print("all tests passed successfully")
