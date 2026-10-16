/// 探活函数：证明 Dart↔Rust 桥接通路可用。
#[flutter_rust_bridge::frb(sync)]
pub fn greet() -> String {
    "siplayer rust bridge ok".to_string()
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // FRB 标准初始化钩子
    flutter_rust_bridge::setup_default_user_utils();
}
