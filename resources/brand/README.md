# 应用图标

`weq.png` 原样复用 WeQ 仓库的 `resources/brand/logo.png`，沿用项目标识与项目许可证。
源图和平台资源均在本仓库维护，正常构建不依赖桌面仓库或额外图像处理库。

在 macOS 上重新生成尺寸：

```sh
swift scripts/generate-app-icons.swift
python3 -m unittest discover -s tests -p test_app_icons.py
```

- iOS / iPadOS：1024 × 1024、不含 alpha 的浅色和深色图标，由 Asset Catalog 生成系统尺寸，不预裁圆角。
- Android：mdpi 至 xxxhdpi 的普通图标，以及 108dp 透明前景 + 白色背景的自适应图标；主体居中限制在 60dp，圆形和其他系统蒙版共用相同内容。
- 新生成的平台 PNG 是构建必需输入，纳入版本管理，不需要构建时运行脚本。

平台依据：[Apple Asset Catalog](https://developer.apple.com/documentation/xcode/configuring-your-app-icon/)、[Android 自适应图标](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)。
