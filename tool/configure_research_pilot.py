"""Prepare ignored, machine-local APK configuration; prints no credentials."""

import argparse
from pathlib import Path
from urllib.parse import urlsplit

from research_receiver.cli import ROOT, credentials


def main():
    parser = argparse.ArgumentParser(description="配置免登录内测包的接收方（不写入管理员密钥）")
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--enable-online", action="store_true", help="明确启用在线兼容构建，普通内测无需使用")
    args = parser.parse_args()
    value = args.endpoint
    try:
        url = urlsplit(value)
        if (not value.isascii() or any(ord(c) <= 32 for c in value) or "\\" in value
                or url.username is not None or url.password is not None or url.query or url.fragment
                or not url.hostname or not url.path.endswith("/api/research/upload")
                or not (url.scheme == "https" or (url.scheme == "http" and url.hostname in {"localhost", "127.0.0.1", "10.0.2.2"}))):
            raise ValueError
        _ = url.port
    except ValueError:
        parser.error("请提供以 /api/research/upload 结尾的 HTTPS 地址；HTTP 仅允许调试回环地址")
    config = credentials(ROOT / ".local/research-receiver")
    destination = ROOT / ".local/research-pilot.properties"
    destination.write_text("endpoint=" + value + "\nenrollmentKey=" + config["enrollment_key"] +
                           "\nonlineEnabled=" + str(args.enable_online).lower() + "\n", encoding="ascii")
    print("Pilot build configuration saved: " + str(destination))
    print("Install limit: 10. Enable new enrollment in the local admin /pilot page.")


if __name__ == "__main__":
    main()
