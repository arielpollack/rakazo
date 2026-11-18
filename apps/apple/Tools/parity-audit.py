"""Inventory Rakazo's published source surfaces; this does not test native parity."""

import argparse
import json
import posixpath
import re
import subprocess


def inventory(checkout, revision):
    def git(*arguments):
        return subprocess.check_output(["git", "-C", checkout, *arguments], text=True)

    commit = git("rev-parse", "--verify", "--end-of-options", revision + "^{commit}").strip()
    paths = set(git("ls-tree", "-r", "--name-only", commit).splitlines())

    def read(path):
        return git("show", f"{commit}:{path}")

    def declaration(path, name):
        return read(path).split(f"export const {name} = {{\n", 1)[1].split("\n};", 1)[0]

    contracts = "packages/contracts/src/"
    blocks_path = next(contracts + name for name in ("threads/message-blocks.ts", "events.ts") if contracts + name in paths)
    blocks = read(blocks_path)
    union = blocks.split('export const MessageBlock = z.discriminatedUnion("kind", [', 1)[1].split("\n]);", 1)[0]
    literals = r'\bkind: z\.literal\("([^"\n]+)"\)'
    kinds = set(re.findall(literals, union))
    for symbol in re.findall(r"^  (\w+),$", union, re.M):
        source = blocks.split(f"const {symbol} =", 1)[1].split("\n\n", 1)[0]
        kinds.add(re.search(literals, source).group(1))

    router = next(contracts + name for name in ("rpc/app-contract.ts", "rpc.ts") if contracts + name in paths)
    root = declaration(router, "appContract")
    declarations = [root]
    for spread in re.findall(r"^  \.\.\.(\w+),$", root, re.M):
        target = re.search(r'import \{ ' + re.escape(spread) + r' \} from "([^"]+)";', read(router)).group(1)
        path = posixpath.normpath(posixpath.join(posixpath.dirname(router), target.removesuffix(".js") + ".ts"))
        declarations.append(declaration(path, spread))

    web = read("apps/web/src/App.tsx")
    prefix = "apps/mobile/app/"
    return {
        "commit": commit,
        "message_blocks": sorted(kinds),
        "mobile_route_files": sorted(path[len(prefix):] for path in paths if path.startswith(prefix) and path.endswith(".tsx") and posixpath.basename(path) not in {"_layout.tsx", "+native-intent.tsx"}),
        "web_literal_paths_in_App_tsx": sorted(set(re.findall(r'\bpath="([^"]+)"', web))),
        "web_path_expressions_in_App_tsx": sorted(set(re.findall(r'\bpath=\{([^}]+)\}', web))),
        "rpc_top_level_keys": sorted({key for section in declarations for key in re.findall(r"^  (\w+):", section, re.M)}),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", help="Local checkout of elie222/rakazo containing the target revision")
    parser.add_argument("revision", nargs="?", default="v0.12.0")
    args = parser.parse_args()
    print(json.dumps(inventory(args.checkout, args.revision), indent=2))
