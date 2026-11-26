-- Scrolls the sidebar tab list top -> bottom -> top twice, 100 steps per leg,
-- by setting its scroll bar's value; prints the step count and elapsed time.
tell application "System Events"
	set p to first process whose bundle identifier is "com.phibrowser.canary.Mac"
	set bar to scroll bar 1 of scroll area 1 of (first UI element of (first window of p whose subrole is "AXStandardWindow") whose role is "AXSplitGroup")
	set steps to 100
	set n to 0
	set t0 to (current date)
	repeat 2 times
		repeat with i from 1 to steps
			set value of bar to i / steps
			set n to n + 1
			delay 0.016
		end repeat
		repeat with i from (steps - 1) to 0 by -1
			set value of bar to i / steps
			set n to n + 1
			delay 0.016
		end repeat
	end repeat
	return "steps=" & n & " seconds=" & ((current date) - t0)
end tell
