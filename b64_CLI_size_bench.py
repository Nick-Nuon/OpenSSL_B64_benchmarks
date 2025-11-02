import os
import glob
import numpy as np
import datetime
import matplotlib.pyplot as plt

# Step 1: Get the latest main benchmark file
main_files = glob.glob('./util/benchmark_results/input_size_vs_time_*.csv')
if not main_files:
    raise FileNotFoundError("No main CSV benchmark files found.")
main_file = max(main_files, key=os.path.getmtime)
print(f"📄 Using latest main file: {main_file}")

# Optionally, specify a control CSV file manually:
control_file = './util/OpenSSL_benchmark_control/input_size_vs_time.csv'  # update this path
use_control = os.path.isfile(control_file)
if use_control:
    print(f"📄 Using control file: {control_file}")
else:
    print("⚠️  Control file not found. Proceeding without it.")

# Step 2: Load CSV data
def load_csv(file_path):
    x_vals = []
    y_vals = []
    with open(file_path, 'r') as f:
        next(f)  # skip header
        for line in f:
            parts = line.strip().split(',')
            if len(parts) != 2:
                continue
            try:
                x_vals.append(int(parts[0]))
                y_vals.append(float(parts[1]))
            except ValueError:
                continue
    return np.array(x_vals), np.array(y_vals)

x, y = load_csv(main_file)
if use_control:
    x_ctrl, y_ctrl = load_csv(control_file)

# Step 3: Fit linear regression to main data
a, b = np.polyfit(x, y, 1)
print(f"✅ Main fit: y = {a:.12f} * x + {b:.12f}")
print(f"   - Slope (ms/byte):   {a:.12f}")
print(f"   - Slope (ms/MiB):    {a * 1024 * 1024:.12f}")
print(f"   - Intercept (ms):    {b:.12f}")

# Step 4: Plot
plt.figure(figsize=(10, 6))
plt.scatter(x, y, s=8, alpha=0.4, label='Main data', color='#7fa7ff')  # pale blue
plt.plot(x, a * x + b, color='blue', linewidth=2, label='Main fit')

if use_control:
    plt.scatter(x_ctrl, y_ctrl, s=8, alpha=0.4, label='Control data', color='#90ee90')  # pale green
    a_c, b_c = np.polyfit(x_ctrl, y_ctrl, 1)
    plt.plot(x_ctrl, a_c * x_ctrl + b_c, color='green', linewidth=2, label='Control fit')
    print(f"✅ Control fit: y = {a_c:.12f} * x + {b_c:.12f}")
    print(f"   - Slope (ms/MiB): {a_c * 1024 * 1024:.12f}")

plt.xlabel("Input size (bytes)")
plt.ylabel("Time (ms)")
plt.title("Base64 Encode: Input Size vs Time")
plt.legend()
plt.grid(True)
plt.tight_layout()
timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
plot_path = f'./benchmark_results/input_size_vs_time_plot_{timestamp}.png'
plt.savefig(plot_path)
print(f"📊 Plot saved to {plot_path}")
plt.show()