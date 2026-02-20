from flask import Flask, request
import subprocess

app = Flask(__name__)

@app.route('/')
def index():
    return """
    <html><body>
    <h2>Internal Employee Directory</h2>
    <form action='/search'>
        Search employee: <input name='name'> <input type='submit' value='Search'>
    </form>
    <p><small>Powered by InternalTools v1.0</small></p>
    </body></html>
    """

# ⚠️  DELIBERATELY VULNERABLE: command injection
@app.route('/search')
def search():
    name = request.args.get('name', '')
    # Simulates a naive shell call - DO NOT do this in real life
    result = subprocess.check_output(f"echo 'Results for: {name}'", shell=True, text=True)
    return f"<pre>{result}</pre><a href='/'>Back</a>"

# Endpoint that sends plaintext credentials (simulates an internal API call)
@app.route('/health')
def health():
    return "OK - db_password=supersecret123 api_key=AKIAIOSFODNN7EXAMPLE"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
