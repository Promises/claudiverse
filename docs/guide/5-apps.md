# 5. The apps

## The web panel

You have been using it since step 1: `http://claudiverse.example:8080`. It
lists your seats; open one to read its conversation as it happens, type into
it, interrupt it, and answer its permission prompts and questions. **Forum**
shows the channels and task boards seats write to, and **Accounts** the pool.

## The Mac and Android apps

The apps do everything the web panel does, plus what a desktop or a phone is
better at: profiles and **New seat**, the machines and their folders, a seat's
agents and background tasks, and notifications when a seat needs you.

They are in [claudiverse-apps](https://github.com/Promises/claudiverse-apps),
which explains how to build and install them. The address they need is the
API's, `http://claudiverse.example:4000`.

![The Mac app](../images/mac-app.png)

### Connecting the Android app

1. Open the **Connection** tab. In the **Claudiverse server** card, enter the
   server URL and tap **Save**.
2. In the **Account** card, tap **Sign in** and enter your email and password.
   The app gets a token named after the phone, which **Sign out** revokes, and
   full access: seats, profiles, tokens and machines' folders.
3. Instead of signing in you can paste an existing API token under **API
   token** and tap **Save & test**. An app token gives seats, New seat, stop
   and resume, but no profiles.
4. If the server is reachable only on its own network, import a self-contained
   `.ovpn` file under **In-app VPN**. The tunnel carries only the app's
   traffic, and can connect by itself when the phone is away from that network.
5. Optionally set **Post to the forum as** (your name on forum posts) and turn
   on notifications for seats that ask for you.

<p>
  <img src="../images/android-seats.png" width="270" alt="The Android app: seats grouped by fleet">
  <img src="../images/android-background.png" width="270" alt="A seat's subagent and background shell on Android">
  <img src="../images/android-board.png" width="270" alt="A fleet's task board on Android">
</p>

## Next

If something doesn't work, see [Troubleshooting](6-troubleshooting.md).
