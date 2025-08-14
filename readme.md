**二次元图片随机下载（termux）（程序100%AI）安卓端**

_“运行image.sh实现二次元图片自由”_

**功能描述：**
	<ins>
```

核心功能
多源下载：支持从多个 API 源下载二次元图片
智能解析：集成 Python 通用 JSON 解析器，支持复杂嵌套结构
多线程下载：高效并行下载，可自定义线程数
分组管理：对 API 进行分组管理，支持添加/删除/重命名分组
自定义记录：可记录图片的元数据信息（如作者、标签等）


```
</ins>

**特点**
```
Python 集成：嵌入式 Python 解析器脚本，无需额外安装
智能 URL 检测：自动识别多种格式的图片
URL自动重试机制：网络问题自动重试，提高下载成功率
格式自动识别：根据 URL 或 Content-Type 确定图片格式
中断处理：支持 Ctrl+C 中断下载，保留已下载内容
```
**配置选项**
```
保存目录：自定义图片保存位置
线程数：根据 CPU 核心数调整
代理设置：支持 HTTP/SOCKS5 代理
日志记录：启用/禁用 URL 记录功能
自动重试：失败任务自动重试
```
**文件说明**
```
api_list.txt：存储 API 配置
downloader_config.txt：存储程序配置
downloaded_urls.log：下载记录日志
json_parser.py：Python 解析器脚本（自动生成）
```

**1.下载termux**

谷歌商店

https://github.com/termux/termux-app

https://termux.dev/en/

从 【F-Droid】（https://f-droid.org/packages/com.termux/） 下载并安装 Termux（推荐使用 F-Droid 版本，更新更稳定）

**步骤 2：启动 Termux 并更新包，安装依赖**

打开 Termux 应用，执行以下命令更新软件包:
```
pkg update
pkg upgrade -y
pkg install python -y
python -m ensurepip --upgrade
pkg install python curl file procps -y
pip install rapidjson 
pip install rapidjson
```
**步骤 3：授予存储权限**

脚本需要访问手机存储，需授予 Termux 存储权限(如果已经可以，访问则跳过）：
```
termux-setup-storage
```

在弹出的对话框中点击 _允许__

＊＊步骤 4：将脚本文件放入 Termux＊＊

方法 1：直接下载到 Termux，运行以下命令
```
curl -O https://github.com/ssjbj/anime-image-downloader/blob/main/image.sh
```
方法 2：通过手机存储复制

将 <ins>image.sh</sup> 文件下载放到手机内部存储的任意目录（如 Downloads）

在 Termux 中运行以下命令复制到 Termux 目录
```
cp /storage/emulated/0/Downloads/image.sh ~/
```
方法3：复制image.sh文件内部文本,在Termux内创建image.sh
```
nano image.sh
```
长按屏幕，选择**Past**粘贴

长按**音量－键**，点击键盘字母**o**后，回车保存

显示：**weite to file : image.sh**,再次回车

长按**音量－键**，点击键盘字母**x**后，回车保存


**步骤 5：赋予脚本执行权限**
```
chmod +x image.sh
```

**步骤 6：运行脚本**
```
./image.sh
```







