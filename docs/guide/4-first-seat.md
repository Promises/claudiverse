# 4. Your first seat

A **profile** is a seat the server knows how to start: its name, its machine and
folder, its model and permission mode. The host agent starts it in tmux and the
seat shows up in the web panel.

The Mac app has a profile editor and a **New seat** button for this. Without it,
two API calls do the same. Run them on the seat machine from step 3.

![A profile in the Mac app](../images/mac-profiles.png)

## Create a profile and start it

Sign in for a token that may manage seats (it asks for your password):

```sh
SERVER=http://claudiverse.example:4000
read -rs -p "Password: " PASSWORD; echo
SUPER=$(jq -n --arg e you@example.com --arg p "$PASSWORD" '{email: $e, password: $p, scope: "super", client: "setup"}' \
  | curl -s "$SERVER/api/auth/login" -H 'content-type: application/json' -d @- | jq -r .token)
```

Make a folder for the seat inside the roots:

```sh
mkdir -p ~/projects/hello
```

Create the profile: the seat `hello` on this machine, in that folder, on the
small Haiku model, allowed to edit files without asking:

```sh
ID=$(jq -n --arg machine "$(hostname)" --arg folder "$HOME/projects/hello" \
        '{name: "hello", machine: $machine, folder: $folder,
          model: "claude-haiku-4-5", permission_mode: "acceptEdits"}' \
  | curl -s "$SERVER/api/profiles" -H "authorization: Bearer $SUPER" \
         -H 'content-type: application/json' -d @- | jq -r '.profile.id')
echo "$ID"
```

It prints the profile's id. Start it:

```sh
curl -s -X POST "$SERVER/api/profiles/$ID/start" -H "authorization: Bearer $SUPER" | jq .
```

## Talk to it

Open the web panel. The dashboard lists **hello**. Open it, type
`Say hello in one sentence.` and press Enter. The reply streams in.

![A seat in the web panel](../images/session.png)

On the machine, `tmux attach -t hello` shows the same session in its terminal
(detach with Ctrl-b d). Whatever you type there shows up in the panel too.

To stop the seat:

```sh
curl -s -X POST "$SERVER/api/profiles/$ID/stop" -H "authorization: Bearer $SUPER"
```

Its conversation stays on the machine, and the next start resumes it.

## Seats you start yourself

If this machine also has its own Claude login, every `claude` you run in a
terminal is a seat too. It is named after its folder, and `/rename` renames it.

## Next

[Connect the apps](5-apps.md).
