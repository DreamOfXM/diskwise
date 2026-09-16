// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiskWise",
    // target 名保持 DiskCleaner / DiskCleanerCore：build.sh 的产物路径、
    // L10n 与知识库的 dev-tree 兜底路径都按它拼，改名只会带来无谓的构建风险。
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "DiskCleanerCore",
            path: "Sources/DiskCleanerCore"
        ),
        .executableTarget(
            name: "DiskCleaner",
            dependencies: ["DiskCleanerCore"],
            path: "Sources/DiskCleaner",
            // 故意不声明 resources：SPM 生成的 Bundle.module 会在找不到 .bundle 时
            // fatalError，并把开发者本机的绝对构建路径烧进发布二进制。
            // safety_db.json 由 build.sh 拷进 Contents/Resources，运行时走 Bundle.main。
            exclude: ["Resources"]
        ),
        // 自检程序：无 XCTest 环境也能跑（纯命令行工具链），断言失败即非零退出。
        // 用法：swift run SelfTest
        .executableTarget(
            name: "SelfTest",
            dependencies: ["DiskCleanerCore"],
            path: "Sources/SelfTest"
        )
    ]
)
