-- View > Toggle Sidebar 24 times, 0.6s apart; prints the elapsed time.
tell application "System Events"
	set p to first process whose bundle identifier is "com.phibrowser.canary.Mac"
	set mi to menu item "Toggle Sidebar" of menu 1 of menu bar item "View" of menu bar 1 of p
	set t0 to (current date)
	repeat 24 times
		click mi
		delay 0.6
	end repeat
	return "toggles=24 seconds=" & ((current date) - t0)
end tell
