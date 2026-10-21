import streamDeck from "@elgato/streamdeck";

import { RunCommand } from "./actions/run-command";

streamDeck.actions.registerAction(new RunCommand());
streamDeck.connect();
