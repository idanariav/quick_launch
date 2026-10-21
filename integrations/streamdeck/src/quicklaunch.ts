import { createConnection } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * A client of QuickLaunch's control socket (decision 0016): one line of JSON per
 * connection, answered with one line. Only the user's own account can connect.
 */
export const socketPath = join(homedir(), "Library", "Application Support", "QuickLaunch", "control.sock");

export type Parameter = {
	id: string;
	title: string;
	kind: string;
	options?: string[];
	default?: string;
	optional: boolean;
};

export type Command = {
	id: string;
	title: string;
	subtitle?: string;
	parameters: Parameter[];
	external: boolean;
};

type Response = { ok: boolean; message?: string; error?: string; commands?: Command[] };

/** Thrown when the app refuses a request or can't be reached. */
export class QuickLaunchError extends Error {}

/** The commands that can run, as `quicklaunch list` shows them. */
export async function listCommands(): Promise<Command[]> {
	return (await send({ type: "list" })).commands ?? [];
}

/** Runs a command and waits for it; resolves with its message, if any. */
export async function runCommand(id: string): Promise<string | undefined> {
	return (await send({ type: "run", id, wait: true })).message;
}

function send(request: object): Promise<Response> {
	return new Promise((resolve, reject) => {
		const socket = createConnection(socketPath);
		const chunks: Buffer[] = [];
		socket.on("connect", () => socket.write(JSON.stringify(request) + "\n"));
		socket.on("data", (chunk) => chunks.push(chunk));
		socket.on("error", (error) => reject(new QuickLaunchError(`QuickLaunch isn't running (${error.message})`)));
		socket.on("end", () => {
			try {
				const response = JSON.parse(Buffer.concat(chunks).toString("utf8")) as Response;
				if (response.ok) resolve(response);
				else reject(new QuickLaunchError(response.error ?? "failed"));
			} catch {
				reject(new QuickLaunchError("QuickLaunch sent something unexpected"));
			}
		});
	});
}
