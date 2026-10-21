import streamDeck, {
	action,
	DidReceiveSettingsEvent,
	KeyDownEvent,
	SendToPluginEvent,
	SingletonAction,
	WillAppearEvent,
} from "@elgato/streamdeck";
import type { JsonValue } from "@elgato/utils";

import { listCommands, runCommand } from "../quicklaunch";

/** The command a key runs, and its title (kept so the key needn't ask QuickLaunch). */
type Settings = {
	command?: string;
	title?: string;
	/** The command `title` belongs to; another one means the title is stale. */
	titleOf?: string;
};

/**
 * "Run QuickLaunch command": the key runs the chosen command through the control
 * socket and shows ✓ or ⚠︎ with the outcome. The settings list every command,
 * grouped by namespace (decision 0019).
 */
@action({ UUID: "com.idanariav.quicklaunch.run" })
export class RunCommand extends SingletonAction<Settings> {
	override async onKeyDown(ev: KeyDownEvent<Settings>): Promise<void> {
		const { command } = ev.payload.settings;
		if (!command) {
			await ev.action.showAlert();
			return;
		}
		try {
			await runCommand(command);
			await ev.action.showOk();
		} catch (error) {
			streamDeck.logger.error(`${command}: ${error instanceof Error ? error.message : error}`);
			await ev.action.showAlert();
		}
	}

	override async onWillAppear(ev: WillAppearEvent<Settings>): Promise<void> {
		if (ev.action.isKey()) await ev.action.setTitle(ev.payload.settings.title ?? "");
	}

	/** The property inspector chose a command: remember its title and show it. */
	override async onDidReceiveSettings(ev: DidReceiveSettingsEvent<Settings>): Promise<void> {
		const settings = ev.payload.settings;
		if (settings.command && settings.titleOf !== settings.command) {
			const command = (await listCommands().catch(() => [])).find((c) => c.id === settings.command);
			settings.title = command?.title;
			settings.titleOf = command ? command.id : undefined;
			await ev.action.setSettings(settings);
		}
		if (ev.action.isKey()) await ev.action.setTitle(settings.title ?? "");
	}

	/** Answers the property inspector's `getCommands` datasource request. */
	override async onSendToPlugin(ev: SendToPluginEvent<JsonValue, Settings>): Promise<void> {
		if (!(ev.payload instanceof Object) || !("event" in ev.payload) || ev.payload.event !== "getCommands") return;
		let items;
		try {
			const groups = new Map<string, { label: string; value: string }[]>();
			for (const command of await listCommands()) {
				const namespace = command.id.split("/")[0];
				groups.set(namespace, [...(groups.get(namespace) ?? []), { label: command.title, value: command.id }]);
			}
			// sdpi-components reads a group as `{ label, children }`.
			items = [...groups].map(([label, children]) => ({ label, children }));
		} catch {
			items = [{ label: "QuickLaunch isn't running", value: "", disabled: true }];
		}
		await streamDeck.ui.sendToPropertyInspector({ event: "getCommands", items });
	}
}
