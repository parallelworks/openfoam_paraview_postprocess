import json, glob, os
import pandas as pd

def get_parameter_dict(case_dict):
    param_dict = {
        'in:case': case_dict['directory']
    }

    for f in case_dict['files']:
        for param in f['parameters']:
            clean_pname = 'in:' + param['placeholder'].replace('__','').replace('@','')
            if clean_pname in param_dict:
                clean_pname = clean_pname + f['path']
            param_dict[clean_pname] = param['value']
            
    return param_dict

def load_csv_files(directory):
    data_frames = []
    
    # Get a list of all CSV files in the directory
    csv_files = [file for file in os.listdir(directory) if file.endswith('.csv')]
    
    for file in csv_files:
        file_path = os.path.join(directory, file)
        
        # Read the CSV file into a DataFrame
        df = pd.read_csv(file_path)
        
        # Prepend "out:" to each column name
        df.columns = ['out:' + column for column in df.columns]

        # Append the DataFrame to the list
        data_frames.append(df)
    
    # Concatenate all DataFrames into a single DataFrame
    result_df = pd.concat(data_frames, ignore_index=True)
    
    return result_df

def get_png_images(case_dir):
    png_dict = {}

    for png in glob.glob(os.path.join(case_dir, '*.png')):
        fname = os.path.basename(png).replace('.png', '')
        png_dict[fname] = os.path.join(os.getcwd(), png)
    return png_dict



if __name__ == '__main__': 
    case_inputs = []
    case_outputs = []
    pngs = []
    datafile = os.path.join(os.getcwd(), 'dex.csv')

    for case_json in glob.glob('*/case.json'):
        case_dir = os.path.dirname(case_json)
        
        with open(case_json, 'r') as cj:
            case_dict = json.load(cj)
            
        input_param_dict = get_parameter_dict(case_dict)
        case_inputs.append(input_param_dict)
        
        csv_df = load_csv_files(case_dir)
        case_outputs.append(csv_df)
        
        pngs.append(get_png_images(case_dir))

    outputs_df = pd.concat(case_outputs, ignore_index=True)
    colorby = outputs_df.columns[-1].replace('out:','')

    inputs_df = pd.DataFrame(case_inputs)
    if not colorby:
        colorby = inputs_df.columns[-1].replace('in', '')

    pngs_df =  pd.DataFrame(pngs)
    pngs_df.columns = ['img:' + column for column in pngs_df.columns]
    joined_df = pd.concat([inputs_df, outputs_df, pngs_df], axis=1)
    joined_df.to_csv('dex.csv', index=False)
    
    html = f"<html style=\"overflow-y:hidden;background:white\"><a style=\"font-family:sans-serif;z-index:1000;position:absolute;top:15px;right:0px;margin-right:20px;font-style:italic;font-size:10px\" href=\"/DesignExplorer/index.html?datafile={datafile}&colorby={colorby}\" target=\"_blank\">Open in New Window</a><iframe width=\"100%\" height=\"100%\" src=\"/DesignExplorer/index.html?datafile={datafile}&colorby={colorby}\" frameborder=\"0\"></iframe></html>"

    with open('dex.html', 'w') as f:
        f.write(html)
