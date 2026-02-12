set previousClipboard to ""

try
	set previousClipboard to (the clipboard as text)
on error
	set previousClipboard to ""
end try

try
	tell application "Zen Browser"
		try
			if not running then return "ERROR: BROWSER_NOT_RUNNING"
			activate
			delay 0.1
			tell application "System Events"
				keystroke "l" using command down
				delay 0.08
				keystroke "c" using command down
			end tell
			delay 0.08
			set currentURL to (the clipboard as text)

			try
				set the clipboard to previousClipboard
			end try

			if currentURL is "" then return "ERROR: NO_ACTIVE_TAB"
			return currentURL
		on error errMsg
			try
				set the clipboard to previousClipboard
			end try
			return "ERROR: EXECUTION_FAILED: " & errMsg
		end try
	end tell
on error errMsg
	try
		set the clipboard to previousClipboard
	end try
	return "ERROR: EXECUTION_FAILED: " & errMsg
end try
