import base64
import sys

# Specify the path to your Base64-encoded HTML file
if len(sys.argv) < 2:
    print("Please provide the file path as a command line argument.")
    sys.exit(1)

file_path = sys.argv[1]

with open(file_path, "r") as file:
    base64_data = file.read().strip()

print(base64_data)
base64_data = base64_data.split(";base64,")[1]
decoded_data = base64.b64decode(base64_data).decode("utf-8")

with open("output.html", "w") as html_file:
    html_file.write(decoded_data)

print("HTML file has been created: output.html")
