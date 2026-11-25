# Spider

[![GitHub release (latest)](https://img.shields.io/github/v/release/111pointer111/spider?style=flat-square)](https://github.com/111pointer111/spider/releases/latest)
[![GitHub downloads](https://img.shields.io/github/downloads/111pointer111/spider/total?style=flat-square)](https://github.com/111pointer111/spider/releases)
[![License](https://img.shields.io/github/license/111pointer111/spider?style=flat-square)](LICENSE)
[![Obsidian min version](https://img.shields.io/badge/Obsidian-%E2%89%A5%201.8.7-blueviolet?style=flat-square)](https://obsidian.md)
[![Obsidian Community](https://img.shields.io/badge/Obsidian-Community-blueviolet?style=flat-square)](https://community.obsidian.md/plugins/spider)

> 🌏 **Other languages**: [中文文档](README.zh-CN.md)

**AI conversations that branch like a spider's web — press `Tab` to spin off a deep-dive from any answer. Explore, compare, and trace back without losing context.**

An Obsidian plugin that turns ChatGPT / Claude / DeepSeek / any OpenAI-compatible API into a **branching knowledge map**. Read an AI answer, hit an unfamiliar term, select the text, press `Tab` — a child node appears, ready for the next question. Infinite depth, instant backtrack, one-click export to Obsidian Canvas / Markdown / Mermaid mindmap.

![spider screenshot](.github/screenshot.png)

[Release notes](CHANGELOG.md)

> The screenshot shows the Chinese interface. Spider follows Obsidian's language on first install, and you can switch between Chinese and English at any time.

## Spider TUI / Neovim

このフォークは Obsidian なしでも使えます。端末 UI に Neovim 0.11 以上、バックエンドに Node.js 22 以上が必要です。このリポジトリでビルドしてください。

```sh
npm ci
npm run build:tui
npm run tui
```

シェルから `spider` で起動するには、このリポジトリのディレクトリで次を実行します。`~/.local/bin` を `PATH` に含めてください。

```sh
mkdir -p ~/.local/bin
ln -s "$PWD/scripts/spider-tui" ~/.local/bin/spider
```

`p` で AI の接続先を選びます。

| 接続先 | 準備 |
|---|---|
| Codex | [Codex CLI](https://developers.openai.com/codex/auth) をインストールし、`codex login` で ChatGPT アカウントにログイン |
| Claude | [Claude Code CLI](https://code.claude.com/docs/en/quickstart) をインストールし、`claude auth login --claudeai` で Claude のサブスクリプションにログイン |
| omp | [omp](https://github.com/can1357/oh-my-pi) をインストールし、`omp login` で使う接続先にログイン。omp のプロファイルと既定モデルを使用。モデルだけ変えるなら `SPIDER_OMP_MODEL=プロバイダー/モデル spider` |

Codex と Claude を直接選んだときは API キーに切り替えません。omp を選んだときの利用枠と課金は、omp が使う接続先と認証に従います。omp は ACP で起動し、組み込みツール・拡張・MCP サーバーは使いません。

既存の Neovim 内で使う場合は、lazy.nvim に次の設定を追加し、`:Spider` を実行します。

```lua
return {
  dir = vim.fn.expand("~/Projects/spider"), -- ビルドしたリポジトリの場所
  cmd = { "Spider", "SpiderBranch", "SpiderImport" },
}
```

| 操作 | キー・コマンド |
|---|---|
| 質問を書く | `i` で入力、`Esc` → `Enter` で送信。`q` で下書きを残して閉じる |
| 回答から分岐する | ビジュアルモードで回答を選んで `Tab`。選択せずに押すと空の分岐 |
| 過去の発言を空の子分岐にコピーする | 親の会話で `V` で範囲を選び、`H` でコピー先を選ぶ。範囲に触れた発言は全文をコピーし、親は変更しない |
| 引用元に戻る／最初の子へ移る | `Shift+Tab` または `←`／`→` |
| 編集中のコードや文章を引用する | 行を選んで `:'<,'>SpiderBranch` |
| ツリーから分岐を開く | `Ctrl+w w` でツリーに移動し、対象行で `Enter` |
| 会話グラフを拡大する | `g`。枝で `Enter` を押すと会話を開く。`g` / `Esc` で戻る |
| 会話ペインの Markdown 装飾を切り替える | `r` |
| AI の接続先を選ぶ／送信を中止する | `p`／`x` |
| マップ一覧／新規作成／Markdown 書き出し | `m`／`n`／`e` |
| 会話を新しいマップとして取り込む | `I` または `:SpiderImport path/to/chat.json` |
| Spider を閉じる | `q` |

送信すると質問がすぐ表示され、会話ペインの上部に応答待ちのアニメーション、経過時間、`x` で中止できることが表示されます。中止またはエラーになった質問は会話履歴に保存されず、`i` で下書きに戻れます。

会話ペインは [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) で見出し・表・コードブロックなどを整形します。Neovim 内では既存のプラグイン設定を使います。単体の `spider` は `stdpath("data")/lazy/render-markdown.nvim` のプラグインだけを読み込み、別の場所にある場合は `SPIDER_MARKDOWN_RUNTIME` で指定できます。プラグインがない場合は Markdown の構文強調だけになります。装飾を切り替えても本文や引用位置は変わりません。

マップは `~/Spider/maps/` に保存され、Markdown の既定の書き出し先は `~/Spider/` です。初回起動時に旧保存先（通常 `~/.local/share/spider-tui`）のマップをコピーします。元のデータは残ります。保存先を変更する場合は `SPIDER_DATA_DIR` を設定してください。

取り込み・テキスト選択・分岐だけでは外部に送信しません。質問を送信したときに、その分岐の履歴、引用、親トピックが選んだ接続先に渡ります。

### Import a ChatGPT conversation

移したい **ChatGPT の会話**に下の指示文を貼ります。返ってきた JSON 本体を UTF-8 の `chat.json` に保存し、`:SpiderImport ~/Downloads/chat.json` または Spider の `I` で取り込みます。

```text
このチャットで、この依頼より前に交わした会話を Spider に移したいです。
あなたが参照できる範囲の私の発言とあなたの回答を、古い順に、1 発言ずつ JSON にしてください。
要約・翻訳・補完はせず、本文、Markdown、コードをそのまま残してください。
見えていない発言は推測せず、この依頼や、この依頼への返事も含めないでください。
私の発言は user、あなたの回答は assistant とし、次の形式で有効な JSON オブジェクトだけを返してください。説明やコードフェンスは不要です。改行や引用符は JSON としてエスケープしてください。

{"format":"spider-chat-v1","title":"会話を表す短いタイトル","messages":[{"role":"user","content":"発言本文"},{"role":"assistant","content":"回答本文"}]}
```

発言は元の順序で新しいマップのルートに入ります。長い会話では ChatGPT が古い発言を再現できない場合があるため、元のチャットと照らし合わせてください。添付ファイルやツール結果はこの形式の対象外です。

---

## 🤔 Why Spider?

| Scenario | Plain AI chat | Spider |
|---|---|---|
| Mid-answer, want to drill into a term | Copy-paste → new window → lose the original thread | Select text → `Tab` → child node carries the context |
| Want to compare 3 phrasings of the same question | Open 3 tabs and alt-tab | Same parent, 3 children, side-by-side |
| Done exploring, want it as notes | Copy-paste into a note, links break | Add personal node notes, then export Markdown + Canvas |
| Want AI to live inside your docs, not a separate tab | Constant window switching | Stay in Obsidian the entire time |

## ⚡ 30-Second Quick Start

1. **Install**: Settings → Community plugins → Browse → search `Spider` → Install → Enable
2. **Configure your API key**: Settings → Spider → fill in `apiBaseUrl` + `apiKey` + `model` (any OpenAI-compatible endpoint)
3. **Create your first map**: Click the Spider ribbon icon (or run command `Spider: New Spider map`) → start chatting
4. **Try Tab-branching**: Select any text in an AI response, press `Tab` — that's it

---

## ✨ Features

### 🌳 Infinite-Depth Branching Chat
- **No depth limit**: drill down as deep as you need; the graph grows with you
- **Optional parent context**: child node requests automatically include parent title / summary / anchor
- **Streaming responses**: typewriter-style real-time rendering with Markdown & code-block highlighting
- **Select-to-branch**: highlight any text in an AI response → `Tab` → the child's "anchor" is that exact highlight
- **Selection hint**: selecting AI answer text shows a clickable “Tab Create branch” hint; clearing the selection hides it
- **Return to source**: parent and breadcrumb navigation restore your reading position and briefly highlight the source passage; other node switches retain their position for this session
- **Auxiliary actions**: retry, summarize, AI auto-title

### 🕸️ Interactive Knowledge Graph
- **Full-tab canvas** powered by React Flow
- **Click a node to switch context**; the chat panel follows automatically
- **Collapse / expand subtrees** to keep large maps clean
- **Auto-layout** via Dagre algorithm with active-path highlighting
- **Drag nodes** — positions persist, the canvas looks the way you left it
- **Personal node notes** — hover the pencil for a preview, click to pin and edit with autosave

### 📦 One-Click Structured Export

```
Spider Maps/
  ├── index.md                  # Obsidian entry-point note
  ├── brief.md                  # Findings, open questions, and progress
  ├── notes.md                  # Personal notes with node paths and depth
  ├── nodes/                    # One Markdown file per node
  ├── map.canvas                # Editable knowledge map
  └── map.svg                   # Sharp, shareable knowledge map image
```

- Canvas nodes are color-coded by state (purple = root / green = understood / gray = archived / blue = open)
- Canvas cards show concept titles, short previews, and links to full notes, with generous spacing
- Follow arrows to explore branches; source anchors stay in the notes instead of overlapping the graph
- SVG keeps card titles and previews visible at any zoom, with the same spacious layout
- Repeated exports create numbered snapshot folders, preserving earlier exports and handwritten additions
- Markdown files cross-link parent / child / index — backlinks wire up the full thinking chain

### 🔌 Works with Any OpenAI-Compatible API
- **Official OpenAI** (`https://api.openai.com/v1`)
- **DeepSeek / Moonshot / Qwen / GLM** (OpenAI-compatible mode)
- **OpenRouter / Together / Groq** (aggregator APIs)
- **Local LLMs**: Ollama, vLLM, LM Studio — all expose OpenAI-compatible endpoints
- **Anthropic Claude via proxy**

> 💡 Because it's the OpenAI Chat Completions spec, you just need a base URL + key + any model name that endpoint supports.

### 🔐 Privacy & Network Disclosure
- The plugin **requires network** to call AI, but **you fully control which endpoint**
- **API key stays local** (Obsidian's plugin data.json); never uploaded
- **Never reads unrelated vault notes** — AI requests only include the current branch plus the context options you enable
- **Maps are 100% local**: stored as `.spider/maps/*.json`, syncable via Obsidian Sync
- **Offline-capable**: knowledge graph, navigation, export, history — everything works offline. Only "send message" needs network.

### 🌐 Bilingual UI
Spider follows Obsidian's language on first install. You can switch between Chinese and English at any time, and newly generated export artifacts use the current Spider interface language.

---

## Learning styles and personal notes

- Settings → Learning style: choose Step by step, Socratic, Concise, or a custom system prompt. Changes apply to your next question.
- Select AI answer text and press `Enter` to save a quote to its node. Existing notes are preserved.
- A two-line Personal notes preview stays above the composer. Expand it to read rendered Markdown, then choose Edit to add your insights. Changes are saved automatically.
- Export packages include `notes.md`, preserving node titles, full paths, depth, and links to original node files.
- No client-side usage analytics are collected.

## ⌨️ Keyboard Shortcuts

| Key | Action |
|---|---|
| `Tab` | With text selected in an AI response → create a branch from that source. On the focused map canvas → create an empty branch. |
| `Shift + Tab` | On the focused map canvas → go to the parent branch |
| `← →` | On the focused map canvas → parent ↔ first child |
| `↑ ↓` | On the focused map canvas → move between sibling nodes |
| `Enter` | Save selected AI text to node notes; send a message inside the composer |
| `Shift + Enter` | Newline (inside composer) |
| `Esc` | Clear current selection |
| `Delete` / `Backspace` | On the focused map canvas → delete the current non-root node |

---

## ⚙️ Settings

| Setting | Description | Default |
|---|---|---|
| API Base URL | OpenAI-compatible endpoint | `https://api.openai.com/v1` |
| API Key | Your API key (password input, stored locally) | — |
| Model | Any model name your endpoint supports | `gpt-4o-mini` |
| Interface Language | Chinese / English | Follows Obsidian |
| Include parent context | Send parent title/summary/anchor with child requests | ✅ on |
| Include full context | Also send other map branches as reference (more tokens) | ❌ off |
| Stream responses | Stream tokens as they arrive | ✅ on |
| Tab to create child nodes | Enable the Tab shortcut | ✅ on |
| Auto-summarize nodes | AI auto-summarizes each node | ❌ off |
| Default export folder | Where export packages go | `Spider Maps` |

---

## 📥 Installation

### From Community Plugins (recommended)

Open **Settings → Community plugins → Browse**, search for `Spider`, then select **Install → Enable**. Configure your API key and model under **Settings → Spider**.

### From GitHub Release (manual installation)
1. Download `main.js`, `manifest.json`, and `styles.css` from the latest [release](https://github.com/111pointer111/spider/releases/latest)
2. Create `<vault>/.obsidian/plugins/spider/`
3. Copy the three files into that directory
4. Restart Obsidian, enable Spider under **Settings → Community plugins**, then configure your API key and model

### From Source (development)
```bash
git clone https://github.com/111pointer111/spider
cd spider
npm install
npm run build
# Copy main.js, manifest.json, styles.css into
# <vault>/.obsidian/plugins/spider/
# Then enable the plugin in Obsidian
```

Or use `npm run link` to symlink the build output to your vault and pair with `npm run dev` for live-reload during development.

---

## 🛠 Development

```bash
npm install        # install dependencies
npm run dev        # watch mode (esbuild)
npm run build      # production build (runs tsc --noEmit first)
npm test           # run vitest tests
npm run test:browser # open the local URL and click Run source navigation checks (mock Obsidian API, no vault access)
npm run link       # symlink build output into your vault
```

### Project Structure

```
src/
  ai/          OpenAI-compatible API provider (streaming + sync + summarize)
  domain/      ChatMap immutable factories + tree ops + guards + Dagre layout
  export/      Markdown / Mermaid / Canvas / SVG / JSON exporters
  state/       Multi-view session store + per-session ViewState
  storage/     Vault JSON persistence (backward-compatible with old directory)
  ui/          React components (graph, chat panel, gallery, modals)
  utils/       ID generation, path handling, activeDocument shim
tests/         vitest unit tests (domain + export + AI layers)
__mocks__/     Obsidian API stub for vitest
```

## 🧭 Roadmap (running list)

- [ ] Multi-select nodes + batch operations
- [ ] Node backlinks (auto-track "which nodes reference me")
- [x] Custom system prompts and teaching styles
- [ ] Optional AI summary attached to export package

---

## 📜 License

[MIT](LICENSE)

---

## 🙏 Credits

- [Obsidian](https://obsidian.md) — the endlessly extensible note app
- [React Flow (@xyflow/react)](https://reactflow.dev/) — canvas engine
- [@dagrejs/dagre](https://github.com/dagrejs/dagre) — auto-layout
- [Feynman Technique](https://en.wikipedia.org/wiki/Feynman_technique) — the pedagogical idea: if you can't explain it simply, you don't understand it
