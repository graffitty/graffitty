extends RefCounted

const CHROMIUM_BASE := 1 << 32

static func key(surface: int) -> String:
	return "c%d" % (surface - CHROMIUM_BASE) if surface > CHROMIUM_BASE else "t%d" % surface

static func id(address: String) -> int:
	var ordinal := address.substr(1).to_int()
	if ordinal < 1 or ordinal >= CHROMIUM_BASE or str(ordinal) != address.substr(1):
		return -1
	match address.left(1):
		"t": return ordinal
		"c": return CHROMIUM_BASE + ordinal
	return -1
