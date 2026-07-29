#!/usr/bin/env python3

import argparse
import sys
from pandas import read_csv
from matplotlib import pyplot as plt
import pandas as pd


def main(csv_file, put, runs, cut_off, step, out_file, fuzzers):
  df = read_csv(csv_file)
  required_columns = {
      'time', 'subject', 'fuzzer', 'run', 'state_type', 'state'
  }
  missing_columns = required_columns.difference(df.columns)
  if missing_columns:
    print(
        "State CSV schema error: missing {}".format(
            ", ".join(sorted(missing_columns))
        ),
        file=sys.stderr,
    )
    return 1

  df['time'] = pd.to_numeric(df['time'], errors='coerce')
  df['state'] = pd.to_numeric(df['state'], errors='coerce')
  invalid_rows = df[df[['time', 'state']].isna().any(axis=1)]
  if not invalid_rows.empty:
    print(
        "State CSV contains {} row(s) with invalid time/state values.".format(
            len(invalid_rows)
        ),
        file=sys.stderr,
    )
    return 1

  mean_list = []

  for subject in [put]:
    for fuzzer in fuzzers:
      for data_type in ['nodes', 'edges']:
        df1 = df[(df['subject'] == subject) & 
                         (df['fuzzer'] == fuzzer) & 
                         (df['state_type'] == data_type)]

        run_frames = []
        for run in range(1, runs + 1):
          # Metrics can grow several times within one second. Preserve archive
          # order for equal timestamps so the last row remains the latest
          # cumulative graph size.
          df2 = df1[df1['run'] == run].sort_values('time', kind='stable')
          if df2.empty:
            print(
                "No {} state data for {} run {}; excluding it from the mean.".format(
                    data_type, fuzzer, run
                ),
                file=sys.stderr,
            )
            continue
          run_frames.append(df2)

        for time in range(0, cut_off + 1, step):
          values = []
          for df2 in run_frames:
            start = df2.iloc[0]['time']
            df3 = df2[df2['time'] <= start + time * 60]
            if not df3.empty:
              values.append(df3.iloc[-1]['state'])

          if values:
            mean_list.append(
                (subject, fuzzer, data_type, time, sum(values) / len(values))
            )

  if not mean_list:
    print(
        "No valid state measurements were found; state plot was not generated.",
        file=sys.stderr,
    )
    return 1

  mean_df = pd.DataFrame(mean_list, columns = ['subject', 'fuzzer', 'data_type', 'time', 'data'])

  print("Saving mean logs into file...")
  mean_df.to_csv("mean_plot_data.csv", index=False)

  fig, axes = plt.subplots(1, 2, figsize = (10, 20))
  fig.suptitle("State coverage analysis")

  for key, grp in mean_df.groupby(['fuzzer', 'data_type']):
    if key[1] == 'nodes':
      axes[0].plot(grp['time'], grp['data'], label=key[0])
      #axes[0].set_title('Edge coverage over time (#edges)')
      axes[0].set_xlabel('Time (in min)')
      axes[0].set_ylabel('#nodes')
    if key[1] == 'edges':
      axes[1].plot(grp['time'], grp['data'], label=key[0])
      axes[1].set_xlabel('Time (in min)')
      axes[1].set_ylabel('#edges')

  for i, ax in enumerate(fig.axes):
    if ax.lines:
      ax.legend(loc='upper left')
    ax.grid()

  #Save to file
  plt.savefig(out_file)
  plt.close(fig)
  return 0

# Parse the input arguments
if __name__ == '__main__':
    parser = argparse.ArgumentParser()    
    parser.add_argument('-i','--csv_file',type=str,required=True,help="Full path to plot_data.csv")
    parser.add_argument('-p','--put',type=str,required=True,help="Name of the subject program")
    parser.add_argument('-r','--runs',type=int,required=True,help="Number of runs in the experiment")
    parser.add_argument('-c','--cut_off',type=int,required=True,help="Cut-off time in minutes")
    parser.add_argument('-s','--step',type=int,required=True,help="Time step in minutes")
    parser.add_argument('-o','--out_file',type=str,required=True,help="Output file")
    parser.add_argument('-f','--fuzzers', nargs='+',required=True,help="List of fuzzers")
    args = parser.parse_args()
    sys.exit(
        main(
            args.csv_file,
            args.put,
            args.runs,
            args.cut_off,
            args.step,
            args.out_file,
            args.fuzzers,
        )
    )
