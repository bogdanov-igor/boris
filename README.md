# Boris

[Русский](#русский) · [English](#english)

## Русский

Морж в строке меню Mac, который присматривает за Claude.

Если вы работаете с Claude в нескольких местах сразу, картина быстро теряется. В терминале идёт одна сессия, в VS Code другая, где-то крутится workflow на десяток агентов, а в Cowork готовится отчёт. Что из этого ещё работает, что упало, сколько потрачено и кто сейчас ждёт вашего ответа? Чтобы это понять, приходится открывать всё по очереди.

Boris показывает это в одном месте.

**Приложение ещё в разработке, устанавливать пока нечего.** Сейчас здесь только требования (`openspec/`) и макеты (`design/`), код появится следом.

### Что он будет делать

- Показывать проекты, сессии и агентов и то, чем они заняты прямо сейчас.
- Считать токены, лимиты плана и доплаты.
- Объяснять, что упало и почему. Например, когда workflow пишет `completed`, а все его агенты на самом деле упали из-за лимита.
- Давать ответить на запросы Claude, не переключая окно: разрешения, вопросы, планы.
- Сообщать о важном через уведомления Mac, звук и Telegram.
- Показывать, сколько всё это занимает процессора и памяти.

Жить он будет там, где вам удобно: в строке меню, в чёлке, в маленьком окне или в обычном. Режимов два: простой, чтобы понять, нужны ли вы, и технический, чтобы разобраться в деталях.

### Что с данными

Boris работает на вашем Mac, без аккаунта и своего сервера. Он читает файлы, которые Claude и так пишет на диск, и никуда не отправляет промпты, команды и код. Настройки Claude он меняет, только если вы сами подключите ответы на запросы.

Интернет нужен для обновлений и лимитов, а ещё для Telegram, если вы его включите.

### Откуда морж

Это морж Борис: котелок, монокль и сигара. Характером он в Черчилля, так что новости сообщает с достоинством, даже если всё упало.

### Лицензия

Код под MIT. Морж, его реплики и звуки защищены, подробности в [LICENSE](LICENSE).

Это независимый проект, он не связан с Anthropic. Автор: Игорь Богданов.

## English

A walrus in your Mac menu bar that keeps an eye on Claude.

When you work with Claude in several places at once, it gets hard to keep track. One session is running in the terminal, another in VS Code, a workflow with a dozen agents is going somewhere, and Cowork is putting together a report. Which of these are still working, what has failed, how much has it cost, and who is waiting for your answer right now? To find out, you end up opening everything one by one.

Boris shows all of this in one place.

**The app is still in development, so there is nothing to install yet.** For now this repository only has the requirements (`openspec/`, in Russian) and the mockups (`design/`). The code comes next.

### What it will do

- Show your projects, sessions and agents, and what they are doing right now.
- Count tokens, plan limits and extra spend.
- Explain what failed and why. For example, when a workflow says `completed` but all of its agents actually died on a usage limit.
- Let you answer Claude's requests without switching windows: permissions, questions and plans.
- Tell you what matters through Mac notifications, sound and Telegram.
- Show how much CPU and memory all of this is taking.

It will live wherever suits you: in the menu bar, in the notch, in a small window or a regular one. There are two modes: a simple one to see whether you are needed, and a technical one for the details.

### What happens to your data

Boris runs on your Mac, with no account and no server of its own. It reads the files Claude already writes to disk and does not send your prompts, commands or code anywhere. It only changes Claude's settings if you choose to connect request answering.

It needs the internet for updates and limits, and for Telegram if you turn it on.

### About the walrus

His name is Boris: bowler hat, monocle and a cigar. He takes after Churchill, so he delivers the news with dignity even when everything has fallen over.

### License

The code is under MIT. The walrus, his lines and his sounds are protected, see [LICENSE](LICENSE) for details.

This is an independent project, not affiliated with Anthropic. Made by Igor Bogdanov.
