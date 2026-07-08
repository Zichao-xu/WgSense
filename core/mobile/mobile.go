// Package mobile 是 gomobile 绑定入口，供 iOS/Android 原生 app 调用。
// 通过 gomobile bind 编译成 .framework(iOS)/ .aar(Android)。
package mobile

// WgSense 是移动端入口对象。
type WgSense struct {
	// 阶段 4 实现
}

// NewWgSense 创建实例(gomobile 要求导出函数返回导出类型)。
func NewWgSense() *WgSense {
	return &WgSense{}
}
