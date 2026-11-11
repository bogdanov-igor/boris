# Boris

[Русский](#русский) · [English](#english)

## Русский

Морж в строке меню Mac, который присматривает за Claude.

Если вы работаете с Claude в нескольких местах сразу, картина быстро теряется. В терминале идёт одна сессия, в VS Code другая, где-то крутится workflow на десяток агентов, а в Cowork готовится отчёт. Что из этого ещё работает, что упало, сколько потрачено и кто сейчас ждёт вашего ответа? Чтобы это понять, приходится открывать всё по очереди.

Boris показывает это в одном месте.

### Что он делает

- Показывает проекты, сессии и агентов и то, чем они заняты прямо сейчас: в терминале, в VS Code и Cursor, в Claude Desktop и Cowork, а также на других машинах через SSH.
- Считает токены, лимиты плана и доплаты.
- Объясняет, что упало и почему. Например, когда workflow пишет `completed`, а все его агенты на самом деле упали из-за лимита.
- Даёт ответить на запросы Claude, не переключая окно: разрешения, вопросы, планы.
- Сообщает о важном через уведомления Mac, звук и Telegram.
- Показывает, сколько всё это занимает процессора и памяти.

Живёт он там, где вам удобно: в строке меню, в чёлке, в маленьком окне или в обычном. Режимов два: простой, чтобы понять, нужны ли вы, и технический, чтобы разобраться в деталях.

### Как установить

Готовых выпусков пока нет, приложение собирается из исходников. Нужны macOS 14 или новее и Xcode с Swift 6.

```sh
git clone <адрес этого репозитория>
cd boris
scripts/install.sh
```

Скрипт собирает приложение, кладёт его в `~/Applications/Boris.app` и запускает. Тем же скриптом приложение обновляется после `git pull`. Если на Mac нет сертификата разработчика Apple, сборка подписывается без него, и тогда macOS может заново спрашивать разрешения после каждой сборки.

Подписанные выпуски и автоматические обновления появятся позже.

### Хуки необязательны

Без них Boris читает только файлы, которые Claude и так пишет на диск, и уже показывает почти всё. Хуки нужны, чтобы отвечать на запросы Claude прямо из Boris и узнавать о событиях быстрее. Их подключают в настройках, и перед этим Boris показывает, что именно изменится в настройках Claude. Отключаются они там же.

### Что с данными

Boris работает на вашем Mac, без аккаунта и своего сервера. Он не отправляет промпты, команды и код никуда. Настройки Claude он меняет, только если вы сами подключите хуки.

Интернет нужен для лимитов, а ещё для Telegram, если вы его включите.

### Откуда морж

Это морж Борис: котелок, монокль и сигара. Характером он в Черчилля, так что новости сообщает с достоинством, даже если всё упало.

### Лицензия

Код под MIT. Морж, его реплики и звуки защищены, подробности в [LICENSE](LICENSE).

Это независимый проект, он не связан с Anthropic. Автор: Игорь Богданов.

## English

A walrus in your Mac menu bar that keeps an eye on Claude.

When you work with Claude in several places at once, it gets hard to keep track. One session is running in the terminal, another in VS Code, a workflow with a dozen agents is going somewhere, and Cowork is putting together a report. Which of these are still working, what has failed, how much has it cost, and who is waiting for your answer right now? To find out, you end up opening everything one by one.

Boris shows all of this in one place.

### What it does

- Shows your projects, sessions and agents, and what they are doing right now: in the terminal, in VS Code and Cursor, in Claude Desktop and Cowork, and on other machines over SSH.
- Counts tokens, plan limits and extra spend.
- Explains what failed and why. For example, when a workflow says `completed` but all of its agents actually died on a usage limit.
- Lets you answer Claude's requests without switching windows: permissions, questions and plans.
- Tells you what matters through Mac notifications, sound and Telegram.
- Shows how much CPU and memory all of this is taking.

It lives wherever suits you: in the menu bar, in the notch, in a small window or a regular one. There are two modes: a simple one to see whether you are needed, and a technical one for the details.

### How to install

There are no ready-made releases yet, so you build the app from source. You need macOS 14 or later and Xcode with Swift 6.

```sh
git clone <this repository's address>
cd boris
scripts/install.sh
```

The script builds the app, puts it in `~/Applications/Boris.app` and starts it. Run it again after `git pull` to update. Without an Apple Development certificate on your Mac the build is signed without one, and macOS may then ask for permissions again after every build.

Signed releases and automatic updates will come later.

### Hooks are optional

Without them Boris reads only the files Claude already writes to disk, and that shows almost everything. Hooks let you answer Claude's requests right from Boris and make events show up sooner. You connect them in the settings, and Boris first shows exactly what will change in Claude's settings. You disconnect them in the same place.

### What happens to your data

Boris runs on your Mac, with no account and no server of its own. It does not send your prompts, commands or code anywhere. It only changes Claude's settings if you choose to connect the hooks.

It needs the internet for limits, and for Telegram if you turn it on.

### About the walrus

His name is Boris: bowler hat, monocle and a cigar. He takes after Churchill, so he delivers the news with dignity even when everything has fallen over.

### License

The code is under MIT. The walrus, his lines and his sounds are protected, see [LICENSE](LICENSE) for details.

This is an independent project, not affiliated with Anthropic. Made by Igor Bogdanov.
