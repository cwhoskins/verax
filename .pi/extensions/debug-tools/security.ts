/**
 * Debug-tools security helpers.
 *
 * Pure, dependency-free helpers for enforcing the `.tmp/`-only write boundary
 * and constructing the fail-closed bubblewrap (`bwrap`) sandbox. This module
 * deliberately imports nothing but Node built-ins so the unit and sandbox
 * integration tests can run it with `node --experimental-strip-types --test`
 * without a Pi runtime.
 */

import { spawn, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

export const TMP_DIR_NAME = ".tmp";
export const BWRAP_BIN = "bwrap";
export const DEFAULT_SANDBOX_SHELL = "/bin/sh";

export type PathValidation =
	| { ok: true; resolved: string }
	| { ok: false; reason: string };

function lstatNoThrow(p: string): fs.Stats | null {
	try {
		return fs.lstatSync(p);
	} catch {
		return null;
	}
}

/**
 * Find the nearest ancestor of `start` that looks like a git repository root.
 * Accepts both a `.git` directory (normal checkout) and a `.git` file
 * (worktree/submodule). Returns null when no repository root is found.
 */
export function findProjectRoot(start: string): string | null {
	let current = path.resolve(start);
	for (;;) {
		if (fs.existsSync(path.join(current, ".git"))) return current;
		const parent = path.dirname(current);
		if (parent === current) return null;
		current = parent;
	}
}

/** Canonical `.tmp/` path for a repository root. */
export function getTmpRoot(repoRoot: string): string {
	return path.join(repoRoot, TMP_DIR_NAME);
}

/**
 * Ensure the `.tmp/` root is a real directory and not a symlink. Creates it
 * (and only it) when missing. Throws on any unsafe state so callers fail
 * closed rather than silently redirecting writes through a symlink.
 */
export function ensureTmpRootSafe(repoRoot: string, tmpRoot = getTmpRoot(repoRoot)): string {
	const existing = lstatNoThrow(tmpRoot);
	if (existing?.isSymbolicLink()) {
		throw new Error(`Refusing debug tools: ${tmpRoot} is a symlink`);
	}
	if (existing && !existing.isDirectory()) {
		throw new Error(`Refusing debug tools: ${tmpRoot} exists and is not a directory`);
	}
	if (!existing) {
		try {
			fs.mkdirSync(tmpRoot, { recursive: true });
		} catch (err) {
			throw new Error(
				`Refusing debug tools: cannot create ${tmpRoot}: ${err instanceof Error ? err.message : String(err)}`,
			);
		}
	}
	// Re-check after creation so a racing symlink cannot slip through.
	const final = lstatNoThrow(tmpRoot);
	if (!final || final.isSymbolicLink() || !final.isDirectory()) {
		throw new Error(`Refusing debug tools: ${tmpRoot} is not a real directory`);
	}
	return tmpRoot;
}

/**
 * Validate that a candidate path resolves inside the `.tmp/` root using
 * component-aware containment plus symlink checks. The result is safe to
 * re-run immediately before mutation (TOCTOU defense), but the caller should
 * still revalidate inside a file-mutation queue.
 */
export function validateTmpPath(
	repoRoot: string,
	candidate: string,
	tmpRoot = getTmpRoot(repoRoot),
): PathValidation {
	// The root itself must never be a symlink; a symlinked `.tmp` root would
	// redirect every "safe" write elsewhere on the host.
	const rootStat = lstatNoThrow(tmpRoot);
	if (rootStat?.isSymbolicLink()) {
		return { ok: false, reason: `${tmpRoot} is a symlink` };
	}

	const abs = path.isAbsolute(candidate)
		? path.normalize(candidate)
		: path.resolve(repoRoot, candidate);

	const rel = path.relative(tmpRoot, abs);
	if (rel === "") {
		return { ok: false, reason: "target is the .tmp directory itself" };
	}
	if (rel.startsWith("..") || path.isAbsolute(rel)) {
		return { ok: false, reason: `target escapes ${tmpRoot}` };
	}

	// Walk existing components under `.tmp/`. Any symlink in the path must
	// still resolve inside `.tmp/`, otherwise a link like `.tmp/link -> ~` would
	// turn an apparently-contained write into a host write.
	let current = tmpRoot;
	for (const component of rel.split(path.sep)) {
		if (component === "" || component === ".") continue;
		current = path.join(current, component);
		const stat = lstatNoThrow(current);
		if (!stat) break; // Missing component: nothing below it can be a symlink.
		if (!stat.isSymbolicLink()) continue;

		let real: string;
		try {
			real = fs.realpathSync(current);
		} catch (err) {
			return {
				ok: false,
				reason: `cannot resolve symlink ${component}: ${err instanceof Error ? err.message : String(err)}`,
			};
		}
		const realRel = path.relative(tmpRoot, real);
		if (realRel.startsWith("..") || path.isAbsolute(realRel)) {
			return { ok: false, reason: `symlink ${component} escapes ${tmpRoot}` };
		}
	}

	return { ok: true, resolved: abs };
}

/**
 * Locate `bwrap` on a PATH. Uses the supplied env (or process.env) so tests
 * can simulate a missing binary without mutating the real environment.
 */
export function findBwrapOnPath(env: NodeJS.ProcessEnv = process.env): string | null {
	const pathKey = Object.keys(env).find((key) => key.toLowerCase() === "path") ?? "PATH";
	const dirs = (env[pathKey] ?? "").split(path.delimiter).filter(Boolean);
	for (const dir of dirs) {
		const candidate = path.join(dir, BWRAP_BIN);
		try {
			fs.accessSync(candidate, fs.constants.X_OK);
			const stat = fs.statSync(candidate);
			if (stat.isFile()) return candidate;
		} catch {
			// Keep scanning.
		}
	}
	return null;
}

export interface SandboxArgsOptions {
	repoRoot: string;
	tmpRoot: string;
	command: string;
	shellPath?: string;
}

/**
 * Build the bwrap argv. The command is passed as a single trailing argument
 * after `--`, never interpolated into a host-side shell string. The host-side
 * spawn must use `shell: false`.
 */
export function buildSandboxArgs(options: SandboxArgsOptions): string[] {
	const shell = options.shellPath ?? DEFAULT_SANDBOX_SHELL;
	return [
		"--die-with-parent",
		"--unshare-net",
		"--unshare-ipc",
		"--unshare-pid",
		"--ro-bind",
		"/",
		"/",
		"--dev",
		"/dev",
		"--proc",
		"/proc",
		"--tmpfs",
		"/tmp",
		"--chdir",
		options.repoRoot,
		"--bind",
		options.tmpRoot,
		options.tmpRoot,
		"--",
		shell,
		"-c",
		options.command,
	];
}

export interface SandboxRunOptions {
	repoRoot: string;
	tmpRoot: string;
	command: string;
	onData?: (data: Buffer) => void;
	signal?: AbortSignal;
	/** Timeout in seconds. */
	timeout?: number;
	env?: NodeJS.ProcessEnv;
	bwrapPath?: string;
	shellPath?: string;
}

function killProcessGroup(child: ChildProcess): void {
	if (!child.pid) return;
	try {
		process.kill(-child.pid, "SIGKILL");
	} catch {
		try {
			child.kill("SIGKILL");
		} catch {
			// Already gone.
		}
	}
}

/**
 * Run a command inside the fail-closed bwrap sandbox.
 *
 * Resolves with the sandboxed command's exit code (which may be non-zero);
 * rejects for sandbox setup failures, aborts, and timeouts. There is no
 * unsandboxed fallback.
 */
export function runSandboxedCommand(options: SandboxRunOptions): Promise<{ exitCode: number | null }> {
	return new Promise((resolve, reject) => {
		const { repoRoot, tmpRoot, command, onData, signal, timeout, env } = options;

		const bwrapPath = options.bwrapPath ?? findBwrapOnPath(options.env);
		if (!bwrapPath) {
			reject(
				new Error(
					"debug_bash requires bwrap (bubblewrap) on PATH; refusing to run unsandboxed",
				),
			);
			return;
		}
		if (process.platform !== "linux") {
			reject(
				new Error(
					"debug_bash sandbox is Linux-only (bubblewrap); refusing to run unsandboxed",
				),
			);
			return;
		}
		try {
			ensureTmpRootSafe(repoRoot, tmpRoot);
		} catch (err) {
			reject(err);
			return;
		}
		if (!fs.existsSync(repoRoot)) {
			reject(new Error(`Repository root does not exist: ${repoRoot}`));
			return;
		}

		const args = buildSandboxArgs({
			repoRoot,
			tmpRoot,
			command,
			shellPath: options.shellPath,
		});

		const child = spawn(bwrapPath, args, {
			cwd: repoRoot,
			detached: process.platform !== "win32",
			env,
			stdio: ["ignore", "pipe", "pipe"],
			shell: false,
			windowsHide: true,
		});

		let settled = false;
		let timedOut = false;
		let timeoutHandle: NodeJS.Timeout | undefined;

		function cleanup() {
			if (timeoutHandle) clearTimeout(timeoutHandle);
			signal?.removeEventListener("abort", onAbort);
		}
		function fail(err: Error) {
			if (settled) return;
			settled = true;
			cleanup();
			reject(err);
		}
		function succeed(code: number | null) {
			if (settled) return;
			settled = true;
			cleanup();
			resolve({ exitCode: code });
		}

		const onAbort = () => killProcessGroup(child);

		if (timeout !== undefined && timeout > 0) {
			timeoutHandle = setTimeout(() => {
				timedOut = true;
				killProcessGroup(child);
			}, timeout * 1000);
		}

		child.stdout?.on("data", (data) => onData?.(data));
		child.stderr?.on("data", (data) => onData?.(data));
		child.on("error", (err) => fail(err instanceof Error ? err : new Error(String(err))));

		if (signal) {
			if (signal.aborted) onAbort();
			else signal.addEventListener("abort", onAbort, { once: true });
		}

		child.on("close", (code) => {
			if (signal?.aborted) fail(new Error("aborted"));
			else if (timedOut) fail(new Error(`timeout:${timeout}`));
			else succeed(code);
		});
	});
}
