-- Last-resort fallback: click through Control Center the way a human would.
--
-- This is deliberately the bottom rung. UI scripting breaks whenever Apple
-- reshuffles Control Center, and it needs Accessibility permission for
-- SidecarReconnect in System Settings > Privacy & Security > Accessibility.
--
-- The private-API path is better in every way. Reach for this only when a
-- macOS update has broken that and you need the iPad back today.

on run argv
	set deviceName to ""
	if (count of argv) > 0 then set deviceName to item 1 of argv

	tell application "System Events"
		if not (UI elements enabled) then
			error "Accessibility permission is not granted." number 1
		end if

		tell process "ControlCenter"
			-- Some Macs show a dedicated Screen Mirroring menu bar extra; when
			-- it's there it's one click shallower and far more reliable.
			set openedDirectly to false
			try
				click (first menu bar item of menu bar 1 whose description contains "Screen Mirroring")
				set openedDirectly to true
			end try

			if not openedDirectly then
				try
					click (first menu bar item of menu bar 1 whose description contains "Control Center")
				on error
					error "Could not open Control Center from the menu bar." number 2
				end try
				delay 0.8
				try
					click (first button of window 1 whose name contains "Screen Mirroring")
				on error
					try
						click (first UI element of window 1 whose name contains "Screen Mirroring")
					on error
						error "Could not find the Screen Mirroring control." number 3
					end try
				end try
			end if

			delay 1.2

			-- Pick the iPad. With no name given, take the first device row that
			-- isn't the Screen Mirroring header itself.
			set clicked to false
			try
				if deviceName is "" then
					click (first checkbox of window 1 whose name does not contain "Screen Mirroring")
				else
					click (first checkbox of window 1 whose name contains deviceName)
				end if
				set clicked to true
			end try

			if not clicked then
				try
					if deviceName is "" then
						click (first button of scroll area 1 of window 1)
					else
						click (first button of window 1 whose name contains deviceName)
					end if
					set clicked to true
				end try
			end if

			if not clicked then
				key code 53 -- escape, so we don't leave the panel hanging open
				error "Could not find a device row to click." number 4
			end if

			delay 2
			key code 53
		end tell
	end tell

	return "clicked"
end run
