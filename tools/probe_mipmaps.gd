extends SceneTree
func _init() -> void:
	var tex: Texture2D = load("res://content/textures/blocks_atlas.png")
	print("loaded: ", tex, " class=", tex.get_class() if tex else "null")
	if tex:
		var img := tex.get_image()
		print("   size=", img.get_size(), " format=", img.get_format(), " mipmaps=", img.has_mipmaps(), " mipmap_count=", img.get_mipmap_count())
		print("   pixel(0,0)=", img.get_pixel(0,0), " water tile pixel(56,24)=", img.get_pixel(56,24))
	quit(0)
