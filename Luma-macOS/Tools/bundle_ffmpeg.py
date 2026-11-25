#!/usr/bin/env python3
"""把带 libplacebo 的 ffmpeg / ffprobe 与其全部动态库打包成可搬移运行时。

用法：
  bundle_ffmpeg.py --ffmpeg <path> --ffprobe <path> --moltenvk <dylib> --out <Resources 目录>

输出结构：
  <out>/bin/ffmpeg
  <out>/bin/ffprobe
  <out>/lib/*.dylib
  <out>/lib/MoltenVK_icd.json

所有依赖都会被改写成 @loader_path，运行时不再引用 /opt/homebrew。
"""

import argparse
import collections
import os
import shutil
import subprocess
import sys


def otool_deps(path):
    try:
        output = subprocess.check_output(["otool", "-L", path],
                                          stderr=subprocess.DEVNULL, text=True)
    except subprocess.CalledProcessError:
        return []
    return [line.strip().split(" ")[0] for line in output.splitlines()[1:]]


def otool_rpaths(path):
    try:
        lines = subprocess.check_output(["otool", "-l", path],
                                         stderr=subprocess.DEVNULL, text=True).splitlines()
    except subprocess.CalledProcessError:
        return []
    rpaths = []
    for index, line in enumerate(lines):
        if "LC_RPATH" in line and index + 2 < len(lines):
            value = lines[index + 2]
            if "path " in value:
                rpaths.append(value.split("path ")[1].split(" (offset")[0].strip())
    return rpaths


def resolve(origin, dependency, rpaths):
    """把一条依赖解析成真实路径；解析不了（系统框架等）返回 None。"""
    if dependency.startswith("/opt/homebrew/") or dependency.startswith("/usr/local/"):
        return os.path.realpath(dependency)
    if dependency.startswith("@loader_path/"):
        return os.path.realpath(os.path.join(os.path.dirname(origin),
                                             dependency[len("@loader_path/"):]))
    if dependency.startswith("@rpath/"):
        tail = dependency[len("@rpath/"):]
        for rpath in rpaths:
            base = rpath
            if rpath.startswith("@loader_path/"):
                base = os.path.join(os.path.dirname(origin), rpath[len("@loader_path/"):])
            candidate = os.path.join(base, tail)
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
    return None


def collect(roots):
    """遍历依赖闭包，返回 {真实路径: (依赖列表, rpath 列表)}。"""
    graph = {}
    unresolved = []
    queue = list(roots)
    while queue:
        current = os.path.realpath(queue.pop())
        if current in graph:
            continue
        deps = otool_deps(current)
        rpaths = otool_rpaths(current)
        graph[current] = (deps, rpaths)
        for dependency in deps:
            target = resolve(current, dependency, rpaths)
            if target and os.path.exists(target):
                queue.append(target)
            elif dependency.startswith(("@rpath", "@loader_path",
                                        "/opt/homebrew", "/usr/local")):
                unresolved.append((current, dependency))
    return graph, unresolved


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--ffprobe", required=True)
    parser.add_argument("--moltenvk", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    binary_dir = os.path.join(args.out, "bin")
    library_dir = os.path.join(args.out, "lib")
    shutil.rmtree(binary_dir, ignore_errors=True)
    shutil.rmtree(library_dir, ignore_errors=True)
    os.makedirs(binary_dir)
    os.makedirs(library_dir)

    roots = [args.ffmpeg, args.ffprobe, args.moltenvk]
    graph, unresolved = collect(roots)
    if unresolved:
        for origin, dependency in unresolved[:10]:
            print("未解析的依赖：%s -> %s" % (origin, dependency), file=sys.stderr)
        print("依赖不完整，终止打包", file=sys.stderr)
        return 1

    names = {}
    for path in graph:
        name = os.path.basename(path)
        names[path] = name
    duplicates = [name for name, count in collections.Counter(names.values()).items()
                  if count > 1]
    if duplicates:
        print("存在同名依赖，需要先改名：%s" % duplicates, file=sys.stderr)
        return 1

    binaries = {os.path.realpath(args.ffmpeg), os.path.realpath(args.ffprobe)}
    for path in graph:
        target = (os.path.join(binary_dir, names[path]) if path in binaries
                  else os.path.join(library_dir, names[path]))
        shutil.copy2(path, target)
        if path in binaries:
            os.chmod(target, 0o755)

    total_bytes = 0
    for path, (deps, rpaths) in graph.items():
        in_binary = path in binaries
        target = (os.path.join(binary_dir, names[path]) if in_binary
                  else os.path.join(library_dir, names[path]))
        total_bytes += os.path.getsize(target)
        # 二进制在 bin/，依赖在 lib/；dylib 自身也在 lib/。
        prefix = "@loader_path/../lib/" if in_binary else "@loader_path/"
        if not in_binary:
            subprocess.run(["install_name_tool", "-id", prefix + names[path], target],
                           check=False, stderr=subprocess.DEVNULL)
        for dependency in deps:
            resolved = resolve(path, dependency, rpaths)
            if resolved in names:
                subprocess.run(["install_name_tool", "-change", dependency,
                                prefix + names[resolved], target],
                               check=False, stderr=subprocess.DEVNULL)
        for rpath in rpaths:
            subprocess.run(["install_name_tool", "-delete_rpath", rpath, target],
                           check=False, stderr=subprocess.DEVNULL)

    icd = {
        "file_format_version": "1.0.0",
        "ICD": {
            "library_path": "./libMoltenVK.dylib",
            "api_version": "1.4.0",
            "is_portability_driver": True,
        },
    }
    import json
    with open(os.path.join(library_dir, "MoltenVK_icd.json"), "w", encoding="utf-8") as handle:
        json.dump(icd, handle, ensure_ascii=False, indent=2)

    # install_name_tool 改过头部后原签名失效，未重签的二进制会被系统直接 SIGKILL。
    # 这里先 ad-hoc 签一遍保证产物可独立运行；build.sh 之后还会用发布身份重签。
    for path, _ in graph.items():
        target = (os.path.join(binary_dir, names[path]) if path in binaries
                  else os.path.join(library_dir, names[path]))
        subprocess.run(["codesign", "--force", "--sign", "-", target],
                       check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    print("已打包 %d 个文件，共 %.1f MB（bin: ffmpeg/ffprobe，lib: dylib + ICD）"
          % (len(graph), total_bytes / 1e6))
    return 0


if __name__ == "__main__":
    sys.exit(main())
