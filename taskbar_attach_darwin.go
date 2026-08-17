//go:build darwin

package main

import "time"

func attachTaskbarLyricsWindow() {
	if globalTaskbarLyricsWindow == nil || globalApplication == nil {
		return
	}

	screen := globalApplication.Screen.GetPrimary()
	if screen == nil {
		return
	}

	const (
		windowWidth  = 720
		windowHeight = 70
		bottomGap    = 12
	)

	x := screen.WorkArea.X + (screen.WorkArea.Width-windowWidth)/2
	y := screen.WorkArea.Y + screen.WorkArea.Height - windowHeight - bottomGap
	globalTaskbarLyricsWindow.SetPosition(x, y)
	time.Sleep(10 * time.Millisecond)
}
