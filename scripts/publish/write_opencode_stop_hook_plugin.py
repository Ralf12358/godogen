"""Write the OpenCode stop-post-task-gate plugin to .opencode/plugins/."""

from __future__ import annotations

import sys
from pathlib import Path

PLUGIN_TS = r"""import type { Plugin } from "@opencode-ai/plugin"

export const GodogenStopHook: Plugin = async ({ $, worktree }) => {
  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return
      const script = `${worktree}/.agents/hooks/stop_post_task_gate.py`
      await $`echo '{}' | python3 ${script}`.quiet()
    },
  }
}
"""


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: write_opencode_stop_hook_plugin.py <plugin.ts>", file=sys.stderr)
        return 2

    path = Path(argv[1])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(PLUGIN_TS)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
