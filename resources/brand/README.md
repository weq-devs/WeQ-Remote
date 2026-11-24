# 应用图标

[源图](weq.png)来自 WeQ 的 `resources/brand/logo.png`。在 macOS 上可用下列命令从仓库根目录生成资源并检查。

```sh
swift scripts/generate-app-icons.swift
python3 -m unittest discover -s tests -p test_app_icons.py
```

- iOS／iPadOS 使用 1024 × 1024 的浅色和深色无透明通道图标，圆角由系统裁切。
- Android 提供 mdpi 至 xxxhdpi 图标和自适应图标。自适应前景为 108 dp，主体居中限制在 60 dp。

生成的 PNG 随源码提交，构建直接读取平台资源。
