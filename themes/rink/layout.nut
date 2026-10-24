//
// "rink" - 1984 roller-rink / upside-down-red layout for the arcade2 cocktail table.
//
// The table's screen is physically portrait from the player's seat, but the
// display signal is 1920x1080 with its top toward the coin-slot end. The layout
// is designed in the viewer's portrait space (1080x1920) and rotated left
// (counter-clockwise) here, the same as pressing the rotate-left key once.
// (The RotationControl plugin did not take effect on this install, so the
// rotation lives in the layout.) F1/F2 rotate further for a player on the
// opposite side.
//
fe.layout.base_rotation = RotateScreen.Left;
fe.layout.width = 1080;
fe.layout.height = 1920;

local W = 1080;
local H = 1920;

// ---- backdrop and title -------------------------------------------------
fe.add_image("bg.png", 0, 0, W, H);
local logo = fe.add_image("logo.png", 0, 40, W, 330);

// ---- flyer (left) and crisp snap (right) inside the glowing frame ---------
// The emulator config chains artwork paths, so a game missing a flyer falls
// back to its title screen, then to the placeholder panel behind it.
fe.add_image("placeholder.png", 112, 432, 500, 656);
local flyer = fe.add_artwork("flyer", 112, 432, 500, 656);
flyer.preserve_aspect_ratio = true;
local snap = fe.add_artwork("snap", 636, 432, 336, 656);
snap.preserve_aspect_ratio = true;
snap.smooth = false;   // keep the original pixels sharp instead of blurring them
fe.add_image("frame.png", 20, 340, 1040, 840);

// ---- wheel / marquee logo ------------------------------------------------
local wheel = fe.add_artwork("wheel", 190, 1195, 700, 175);
wheel.preserve_aspect_ratio = true;

// ---- game list: 5 rows, selection in the pill ----------------------------
local ith = 72;
local cy = 1620;
fe.add_image("bar.png", 0, cy - 83, 1080, 166);

for (local i = -2; i <= 2; i++)
{
	local t = fe.add_text("[Title]", 70, cy - ith / 2 + i * ith, 940, ith);
	t.index_offset = i;
	t.font = "BebasNeue-Regular.ttf";
	t.align = Align.Centre;
	t.nomargin = true;
	if (i == 0)
	{
		t.charsize = 64;
		t.set_rgb(255, 255, 255);
	}
	else
	{
		local d = i < 0 ? -i : i;
		t.charsize = 50;
		t.set_rgb(255, 196, 140);
		t.alpha = 255 - d * 85;
	}
}

// ---- info and hints -------------------------------------------------------
local info = fe.add_text("[Manufacturer]  -  [Year]", 0, 1795, W, 50);
info.font = "BebasNeue-Regular.ttf";
info.charsize = 40;
info.align = Align.Centre;
info.set_rgb(46, 196, 182);

local count = fe.add_text("[DisplayName]   [ListEntry] / [ListSize]", 0, 1838, W, 44);
count.font = "BebasNeue-Regular.ttf";
count.charsize = 34;
count.align = Align.Centre;
count.set_rgb(150, 130, 190);

local hint = fe.add_text("PRESS START", 0, 1872, W, 40);
hint.font = "Bungee-Regular.ttf";
hint.charsize = 28;
hint.align = Align.Centre;
hint.set_rgb(255, 176, 66);

// ---- gentle pulse ---------------------------------------------------------
function rink_tick(ttime)
{
	hint.alpha = (170 + 85 * sin(ttime / 420.0)).tointeger();
	logo.alpha = (228 + 27 * sin(ttime / 760.0)).tointeger();
}
fe.add_ticks_callback("rink_tick");
