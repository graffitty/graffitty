extends Control
## Gboard-style QWERTY surface for the desktop mobile capture.
const HEIGHT := 222.0
var centers := {}
var pressed := ""
var shifted := true
var typed := ""

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO,size),Color("#25272b"))
	var word := typed.get_slice(" ",typed.count(" "))
	var font := ThemeDB.fallback_font
	draw_string(font,Vector2(0,25),word,HORIZONTAL_ALIGNMENT_CENTER,size.x,16,Color("#d6d9df"))
	var unit := (size.x-12)/10.0
	for row_index in 4:
		var keys: Array
		match row_index:
			0: keys = Array("q w e r t y u i o p".split(" "))
			1: keys = Array("a s d f g h j k l".split(" "))
			2: keys = Array("⇧ z x c v b n m ⌫".split(" "))
			_: keys = ["?123", ",", " ", ".", "↵"]
		var total := 0.0
		for key in keys: total += width_units(key,row_index)
		var x := (size.x-total*unit)/2
		for key: String in keys:
			var w := width_units(key,row_index)*unit
			var rect := Rect2(x+2,36+row_index*43,w-4,38)
			centers[key] = rect.get_center()
			var box := StyleBoxFlat.new()
			box.set_corner_radius_all(7)
			box.bg_color = Color("#a8c7fa") if pressed==key or key=="↵" else (Color("#555b64") if key in ["⇧","⌫","?123"] else Color("#404348"))
			draw_style_box(box,rect)
			var label := "English" if key==" " else (key.to_upper() if shifted else key)
			var ink := Color("#182333") if key==pressed or key=="↵" else Color("#f1f3f4")
			draw_string(font,rect.position+Vector2(0,25),label,HORIZONTAL_ALIGNMENT_CENTER,rect.size.x,16 if key==" " else 20,ink)
			x += w
	draw_style_box(nav_style(),Rect2(size.x*.5-40,size.y-9,80,4))

func nav_style() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.set_corner_radius_all(2)
	box.bg_color = Color("#c7c9ce")
	return box

func width_units(key: String, row: int) -> float:
	if row==3: return 5.0 if key==" " else 1.25
	if key in ["⇧","⌫"]: return 1.5
	return 1
