/**
 * Claude Bridge — Blockbench plugin for Luckweaver: Infinite Deep.
 *
 * Adds Tools ▸ "Ask Claude (model edit)": describe a change ("make the horns
 * bigger", "add a tail", "recolor the torso crimson") and Claude rewrites the
 * current model's elements in place.
 *
 * Install: Blockbench ▸ File ▸ Plugins ▸ Load Plugin from File ▸ this file.
 * Setup:  Tools ▸ "Claude Bridge: set API key" (stored in Blockbench settings).
 *
 * Color convention: element names end in "|#RRGGBB" — the game's ModelDb
 * reads that as the part tint, so keep it when renaming parts.
 */
(function () {
  let keySetting;

  async function askClaude(prompt, modelJson, apiKey) {
    const body = {
      model: "claude-sonnet-5",
      max_tokens: 8000,
      system:
        "You edit Blockbench models for a chunky voxel dungeon crawler. " +
        "You receive a bbmodel 'elements' array (boxes: from/to in 1/16 m units, " +
        "y-up, model faces -Z, stands on y=0). Names are 'part|#RRGGBB' where the " +
        "hex is the part tint — preserve that convention. Reply with ONLY a JSON " +
        "array of elements (same schema, keep uuids where parts persist).",
      messages: [
        {
          role: "user",
          content:
            "Current elements:\n" + JSON.stringify(modelJson) +
            "\n\nRequested change: " + prompt,
        },
      ],
    };
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
        "anthropic-dangerous-direct-browser-access": "true",
      },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error("Claude API " + res.status + ": " + (await res.text()));
    const data = await res.json();
    let text = data.content.map((c) => c.text || "").join("");
    const start = text.indexOf("[");
    const end = text.lastIndexOf("]");
    if (start < 0 || end < 0) throw new Error("No JSON array in reply");
    return JSON.parse(text.slice(start, end + 1));
  }

  function applyElements(newElements) {
    Undo.initEdit({ elements: Cube.all, outliner: true });
    Cube.all.slice().forEach((c) => c.remove());
    newElements.forEach((el) => {
      const cube = new Cube({
        name: el.name || "part|#c0c0c0",
        from: el.from,
        to: el.to,
        origin: el.origin || [0, 0, 0],
      }).init();
      cube.addTo();
    });
    Undo.finishEdit("Claude edit");
    Canvas.updateAll();
  }

  BBPlugin.register("claude_bridge", {
    title: "Claude Bridge",
    author: "Luckweaver",
    description: "Edit the open model by describing changes to Claude.",
    version: "1.0.0",
    variant: "both",
    icon: "smart_toy",
    onload() {
      keySetting = new Setting("claude_api_key", {
        name: "Claude API key",
        category: "general",
        type: "password",
        value: "",
      });

      new Action("claude_set_key", {
        name: "Claude Bridge: set API key",
        icon: "key",
        click() {
          Blockbench.textPrompt("Anthropic API key", keySetting.value || "", (v) => {
            keySetting.set(v);
            Blockbench.showQuickMessage("Claude key saved.");
          });
        },
      });
      MenuBar.addAction(BarItems.claude_set_key, "tools");

      new Action("claude_edit_model", {
        name: "Ask Claude (model edit)",
        icon: "smart_toy",
        async click() {
          const apiKey = keySetting.value;
          if (!apiKey) {
            Blockbench.showQuickMessage("Set your API key first (Tools menu).", 3000);
            return;
          }
          Blockbench.textPrompt("What should Claude change?", "", async (prompt) => {
            if (!prompt) return;
            const elements = Cube.all.map((c) => ({
              name: c.name, from: c.from.slice(), to: c.to.slice(),
              origin: c.origin.slice(), uuid: c.uuid,
            }));
            Blockbench.showQuickMessage("Asking Claude…", 2000);
            try {
              const out = await askClaude(prompt, elements, apiKey);
              applyElements(out);
              Blockbench.showQuickMessage("Applied Claude's edit ✓", 3000);
            } catch (e) {
              Blockbench.showMessageBox({ title: "Claude Bridge error", message: String(e) });
            }
          });
        },
      });
      MenuBar.addAction(BarItems.claude_edit_model, "tools");
    },
    onunload() {
      BarItems.claude_edit_model?.delete();
      BarItems.claude_set_key?.delete();
    },
  });
})();
