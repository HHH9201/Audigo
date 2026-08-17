//go:build windows

package main

import (
	"log"
	"syscall"
	"unsafe"
)

var taskbarLyricsOffsetX = int32(12)
var taskbarLyricsOffsetY = int32(0)

const (
	taskbarLyricsWidth = int32(720)
	taskbarLyricsX     = int32(12)
	taskbarLyricsY     = int32(0)

	gwlpStyle     = -16
	gwlpExStyle   = -20
	wsChild       = 0x40000000
	wsPopup       = 0x80000000
	wsOverlapped  = 0x00000000
	wsCaption     = 0x00C00000
	wsThickFrame  = 0x00040000
	wsExTopmost   = 0x00000008
	swpNoZOrder   = 0x0004
	swpNoActivate = 0x0010
	swpShowWindow = 0x0040
)

type nativeRect struct {
	left   int32
	top    int32
	right  int32
	bottom int32
}

var (
	user32Taskbar        = syscall.NewLazyDLL("user32.dll")
	findWindowTaskbar    = user32Taskbar.NewProc("FindWindowW")
	setParentTaskbar     = user32Taskbar.NewProc("SetParent")
	getClientRectTaskbar = user32Taskbar.NewProc("GetClientRect")
	setWindowLongTaskbar = user32Taskbar.NewProc("SetWindowLongPtrW")
	setWindowPosTaskbar  = user32Taskbar.NewProc("SetWindowPos")
)

func setTaskbarLyricsPosition(x, y int) {
	taskbarLyricsOffsetX = int32(x)
	taskbarLyricsOffsetY = int32(y)
	attachTaskbarLyricsWindow()
}

func attachTaskbarLyricsWindow() {
	if globalTaskbarLyricsWindow == nil {
		log.Printf("任务栏歌词窗口挂载失败：窗口为空")
		return
	}

	lyricsHWND := uintptr(globalTaskbarLyricsWindow.NativeWindow())
	if lyricsHWND == 0 {
		log.Printf("任务栏歌词窗口挂载失败：未取得原生句柄")
		return
	}

	trayClass, err := syscall.UTF16PtrFromString("Shell_TrayWnd")
	if err != nil {
		log.Printf("任务栏歌词窗口挂载失败：任务栏类名无效: %v", err)
		return
	}
	trayHWND, _, _ := findWindowTaskbar.Call(uintptr(unsafe.Pointer(trayClass)), 0)
	if trayHWND == 0 {
		log.Printf("任务栏歌词窗口挂载失败：未找到 Windows 任务栏")
		return
	}

	setParentResult, _, setParentErr := setParentTaskbar.Call(lyricsHWND, trayHWND)
	if setParentResult == 0 && setParentErr != nil && setParentErr != syscall.Errno(0) {
		log.Printf("任务栏歌词窗口挂载失败：SetParent: %v", setParentErr)
		return
	}

	styleIndex := int32(gwlpStyle)
	exStyleIndex := int32(gwlpExStyle)
	style, _, _ := setWindowLongTaskbar.Call(lyricsHWND, uintptr(styleIndex), uintptr(wsChild))
	_ = style
	setWindowLongTaskbar.Call(lyricsHWND, uintptr(exStyleIndex), 0)

	var client nativeRect
	if ok, _, err := getClientRectTaskbar.Call(trayHWND, uintptr(unsafe.Pointer(&client))); ok == 0 {
		log.Printf("任务栏歌词窗口挂载失败：GetClientRect: %v", err)
		return
	}

	width := taskbarLyricsWidth
	height := client.bottom - client.top
	if height <= 0 {
		height = 48
	}
	if height > 70 {
		height = 70
	}
	maxX := client.right - client.left - width
	if maxX < 0 {
		maxX = 0
	}
	x := taskbarLyricsOffsetX
	if x < 0 {
		x = 0
	}
	if x > maxX {
		x = maxX
	}

	maxY := client.bottom - client.top - height
	if maxY < 0 {
		maxY = 0
	}
	y := taskbarLyricsOffsetY
	if y < 0 {
		y = 0
	}
	if y > maxY {
		y = maxY
	}

	setWindowPosTaskbar.Call(
		lyricsHWND,
		0,
		uintptr(x),
		uintptr(y),
		uintptr(width),
		uintptr(height),
		uintptr(swpNoZOrder|swpNoActivate|swpShowWindow),
	)

	log.Printf("任务栏歌词窗口已嵌入 Windows 任务栏")
}
