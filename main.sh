#!/bin/bash
date
# Resource label
export rlabel=pvhost
export job_dir=$(pwd | rev | cut -d'/' -f1-2 | rev)
export job_id=$(echo ${job_dir} | tr '/' '-')

echo; echo "LOADING AND PREPARING INPUTS"
# Overwrite input form and resource definition page defaults
sed -i "s|__USER__|${PW_USER}|g" inputs.sh
sed -i "s|__USER__|${PW_USER}|g" inputs.json

# Load inputs
source /etc/profile.d/parallelworks.sh
source /etc/profile.d/parallelworks-env.sh
source /pw/.miniconda3/etc/profile.d/conda.sh
conda activate

if [ -f "input_form_resource_wrapper.py" ]; then
    python input_form_resource_wrapper.py
else
    python /swift-pw-bin/utils/input_form_resource_wrapper.py
fi

source inputs.sh
source resources/${rlabel}/inputs.sh

batch_header=resources/${rlabel}/batch_header.sh

sshcmd="ssh -o StrictHostKeyChecking=no ${resource_publicIp}"

echo; echo "CHECKING OPENFOAM JOB DIRECTORY"
jobdir_exists=$(${sshcmd} "[ -d '${paraview_jobdir}' ] && echo 'true' || echo 'false'")

if ! [[ "${jobdir_exists}" == "true" ]]; then
    echo "ERROR: Could find OpenFOAM job directory <${paraview_jobdir}> on remote host <${resource_publicIp}>"
    echo "       Try: ${sshcmd} ls ${paraview_jobdir}"
    exit 1
fi

echo; echo "LOOKING FOR OPENFOAM RESULTS"
ssh_find_cmd="${sshcmd} find ${paraview_jobdir} -maxdepth 2 -name case.foam"
cases_foam=$(${ssh_find_cmd})
if [ -z "${cases_foam}" ]; then
    echo "ERROR: No OpenFOAM results found in directory <${paraview_jobdir}> on remote host <${resource_publicIp}>"
    echo "       Try command <${ssh_find_cmd}>"
    echo "       Exiting workflow"
    exit 1
fi
echo "Found the following OpenFOAM results:"
echo ${cases_foam}

echo; echo "CREATING SLURM WRAPPERS"
for case_foam in ${cases_foam}; do
    echo "  OpenFOAM results: ${case_foam}"
    case_dir=$(dirname ${case_foam} | sed "s|${paraview_jobdir}||g")
    # Case directory in user container
    mkdir -p ${PWD}/${case_dir}
    sbatch_sh=${PWD}/${case_dir}/sbatch_paraview.sh
    chdir=${paraview_jobdir}/${case_dir}
    # Create submit script
    cp ${batch_header} ${sbatch_sh}
    echo "#SBATCH -o ${chdir}/pw-${job_number}.out" >> ${sbatch_sh}
    echo "#SBATCH -e ${chdir}/pw-${job_number}.out" >> ${sbatch_sh}
    echo "#SBATCH --chdir=${chdir}" >> ${sbatch_sh}
    echo "cd ${chdir}"              >> ${sbatch_sh}
    if [[ "${resource_type}" == "slurmshv2" ]]; then
        echo "bash ${resource_workdir}/pw/.pw/remote.sh" >> ${sbatch_sh}
    fi
    echo "export DISPLAY=:0" >> ${sbatch_sh}
    echo "${paraview_load}" | sed "s|___| |g" | tr ';' '\n' >> ${sbatch_sh}
    echo "pvpython ${paraview_script} ${case_foam}"  >> ${sbatch_sh}
    if [[ ${paraview_use_dex} == "true" ]]; then
        rsync_cmd="rsync -avzq -e \"ssh -J ${resource_privateIp}\" --include='*.csv' --include='*.json' --include='*.png' --exclude='*'  ./ usercontainer:${PWD}/${case_dir}"
        echo ${rsync_cmd} >>  ${sbatch_sh}
    fi
    cat ${sbatch_sh}
    scp ${sbatch_sh} ${resource_publicIp}:${paraview_jobdir}/${case_dir}
done


echo; echo "LAUNCHING JOBS"
for case_foam in ${cases_foam}; do
    echo "  OpenFOAM results: ${case_foam}"
    case_dir=$(dirname ${case_foam} | sed "s|${paraview_jobdir}||g")
    remote_sbatch_sh=${paraview_jobdir}/${case_dir}/sbatch_paraview.sh
    echo "  Running:"
    echo "    $sshcmd \"bash --login -c \\"sbatch ${remote_sbatch_sh}\\"\""
    slurm_job=$($sshcmd "bash --login -c \"sbatch ${remote_sbatch_sh}\"" | tail -1 | awk -F ' ' '{print $4}')
    if [ -z "${slurm_job}" ]; then
        echo "    ERROR submitting job - exiting the workflow"
        exit 1
    fi
    echo "    Submitted job ${slurm_job}"
    echo ${slurm_job} > ${PWD}/${case_dir}/slurm_job.submitted
done


echo; echo "CHECKING JOBS STATUS"
while true; do
    date
    submitted_jobs=$(find . -name slurm_job.submitted)

    if [ -z "${submitted_jobs}" ]; then
        if [[ "${FAILED}" == "true" ]]; then
            echo "ERROR: Jobs <${FAILED_JOBS}> failed"
            exit 1
        fi
        echo "  All jobs are completed"
        break
    fi

    for sj in ${submitted_jobs}; do
        slurm_job=$(cat ${sj})
        sj_status=$($sshcmd squeue -j ${slurm_job} | tail -n+2 | awk '{print $5}')
        if [ -z "${sj_status}" ]; then
            mv ${sj} ${sj}.completed
            sj_status=$($sshcmd sacct -j ${slurm_job}  --format=state | tail -n1 | tr -d ' ')
            case_dir=$(dirname ${sj} | sed "s|${PWD}/||g")
            scp ${resource_publicIp}:${paraview_jobdir}/${case_dir}/pw-${job_number}.out ${case_dir}
        fi
        echo "  Slurm job ${slurm_job} status is ${sj_status}"
        if [[ "${sj_status}" == "FAILED" ]]; then
            FAILED=true
            FAILED_JOBS="${slurm_job}, ${FAILED_JOBS}"
        fi
    done
    sleep 60
done

if [[ ${paraview_use_dex} == "true" ]]; then
    python3 dex.py
fi

