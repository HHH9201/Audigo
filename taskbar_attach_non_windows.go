//go:build !windows && !darwin

package main

func setTaskbarLyricsPosition(x, y int) {
	attachTaskbarLyricsWindow()
}

func attachTaskbarLyricsWindow() {}
