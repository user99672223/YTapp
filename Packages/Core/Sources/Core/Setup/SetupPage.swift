import Foundation

/// The single web page served by the TV during setup. Plain HTML + a form POST, so it works in
/// any phone or computer browser without JavaScript.
public enum SetupPage {
    public enum State: Equatable {
        case form(message: String?)
        case success(accountName: String)
        case failure(message: String)
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func html(_ state: State) -> String {
        let body: String
        switch state {
        case .form(let message):
            let note = message.map { "<p class=\"err\">\(escape($0))</p>" } ?? ""
            body = """
            <h1>Tube — connect your YouTube account</h1>
            <ol>
              <li>On a computer, open a <b>private/incognito</b> browser window and sign in to <b>youtube.com</b>.</li>
              <li>Export the cookies for youtube.com (for example with the “Get cookies.txt LOCALLY” extension, allowed in private windows).</li>
              <li>Paste everything below and press <b>Send to TV</b>.</li>
              <li>Then close the private window. Don't press “Sign out” — that would cancel these cookies.</li>
            </ol>
            \(note)
            <form method="post" action="/cookies" accept-charset="utf-8">
              <textarea name="cookies" rows="14" placeholder="# Netscape HTTP Cookie File&#10;.youtube.com	TRUE	/	TRUE	...	SAPISID	..." autofocus required></textarea>
              <button type="submit">Send to TV</button>
            </form>
            <p class="small">The cookies stay on your Apple TV (in its Keychain). They are only sent to YouTube.</p>
            """
        case .success(let name):
            body = """
            <h1>Done ✓</h1>
            <p>Your Apple TV is now signed in as <b>\(escape(name))</b>.</p>
            <p>You can close this page and the private browser window (don't sign out).</p>
            """
        case .failure(let message):
            body = """
            <h1>That didn't work</h1>
            <p class="err">\(escape(message))</p>
            <p><a href="/">Try again</a></p>
            """
        }
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Tube setup</title>
        <style>
          body{font-family:-apple-system,system-ui,sans-serif;max-width:760px;margin:24px auto;padding:0 16px;background:#111;color:#eee;line-height:1.5}
          h1{font-size:1.5em}
          textarea{width:100%;box-sizing:border-box;font-family:ui-monospace,Menlo,monospace;font-size:13px;background:#1c1c1c;color:#eee;border:1px solid #444;border-radius:8px;padding:10px}
          button{margin-top:12px;font-size:1.1em;padding:12px 22px;border:0;border-radius:10px;background:#e33;color:#fff}
          .err{color:#ff7b7b;font-weight:600}
          .small{color:#999;font-size:.9em}
          a{color:#8ab4ff}
        </style></head>
        <body>\(body)</body></html>
        """
    }
}
