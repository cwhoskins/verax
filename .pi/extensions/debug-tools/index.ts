/**
 * Debug Tools Extension
 *
 * Project-local restricted tools for the verax `debugger` agent:
 *
 * - `debug_write` writes only under the repository `.tmp/` directory, with
 *   component-aware containment and symlink checks.
 * - `debug_bash` runs commands inside a fail-closed bubblewrap sandbox:
 *   host filesystem read-only, only `.tmp/` writable, private in-memory
 *   `/tmp`, network namespace isolated, process/session namespaces isolated.
 *
 * Both tools fail closed: there is no unsandboxed fallback and no path outside
 * `.tmp/` is ever writable through these tools.
 */

import { mkdir, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createBashTool, withFileMutationQueue } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import {
	ensureTmpRootSafe,
	findProjectRoot,
	getTmpRoot,
	runSandboxedCommand,
	validateTmpPath,
} from "./security.ts";

const debugWriteSchema = Type.Object({
	path: Type.String({
		description: "Target path relative to the repository root, inside .tmp/",
	}),
	content: Type.String({ description: "File content to write" }),
});

export default function (pi: ExtensionAPI) {
	const hostCwd = process.cwd();
	const repoRoot = findProjectRoot(hostCwd);

	function requireRoot(): string {
		if (!repoRoot) {
			throw new Error("debug tools require a trusted repository root (no .git ancestor found)");
		}
		return repoRoot;
	}

	function requireTmpRoot(): string {
		const root = requireRoot();
		const tmpRoot = getTmpRoot(root);
		ensureTmpRootSafe(root, tmpRoot);
		return tmpRoot;
	}

	pi.registerTool({
		name: "debug_write",
		label: "Debug Write",
		description:
			"Write a file under the repository .tmp/ debugging workspace. The path is relative to the repository root and must stay inside .tmp/; writes anywhere else are rejected.",
		parameters: debugWriteSchema,
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const root = findProjectRoot(ctx.cwd);
			if (!root) {
				throw new Error("debug_write requires a trusted repository root (no .git ancestor found)");
			}
			const tmpRoot = getTmpRoot(root);
			ensureTmpRootSafe(root, tmpRoot);

			// Strip a leading "@" the way built-in path tools do.
			const rawPath = params.path.startsWith("@") ? params.path.slice(1) : params.path;

			const check = (): string => {
				const result = validateTmpPath(root, rawPath, tmpRoot);
				if (!result.ok) {
					throw new Error(`debug_write access violation: ${result.reason}`);
				}
				return result.resolved;
			};

			const resolved = check();
			return withFileMutationQueue(resolved, async () => {
				// Revalidate immediately before mutation to close the TOCTOU gap.
				const finalPath = check();
				await mkdir(dirname(finalPath), { recursive: true });
				await writeFile(finalPath, params.content, "utf8");
				return {
					content: [{ type: "text", text: `Wrote ${rawPath}` }],
					details: { path: finalPath },
				};
			});
		},
	});

	const sandboxedBash = createBashTool(hostCwd, {
		exposeSessionEnvironment: false,
		operations: {
			async exec(command, _cwd, { onData, signal, timeout, env }) {
				const root = requireRoot();
				const tmpRoot = requireTmpRoot();
				return runSandboxedCommand({
					repoRoot: root,
					tmpRoot,
					command,
					onData,
					signal,
					timeout,
					env,
				});
			},
		},
	});

	pi.registerTool({
		...sandboxedBash,
		name: "debug_bash",
		label: "debug bash",
		description:
			"Execute a command in a fail-closed bubblewrap sandbox. The host filesystem is mounted read-only, network is disabled, and only the repository .tmp/ directory is writable (plus an in-memory /tmp). Commands can read the repository but persistent writes outside .tmp/ are denied.",
	});
}
