#!/bin/bash
set -x
source utils/lib.sh
export job_number=$(basename ${PWD})

echo
echo "JOB NUMBER:  ${job_number}"
echo "USER:        ${PW_USER}"
echo "DATE:        $(date)"
echo

wfargs="$(echo $@ | sed "s|__JOB_NUMBER__|${job_number}|g" | sed "s|__USER__|${PW_USER}|g") --job_number ${job_number}"
parseArgs ${wfargs}

# Sets poolname, controller, pooltype and poolworkdir
exportResourceInfo
echo "Resource name:    ${poolname}"
echo "Controller:       ${controller}"
echo "Resource type:    ${pooltype}"
echo "Resource workdir: ${poolworkdir}"
echo

wfargs="$(echo ${wfargs} | sed "s|__RESOURCE_WORKDIR__|${poolworkdir}|g")"
wfargs="$(echo ${wfargs} | sed "s|--_pw_controller pw.conf|--_pw_controller ${controller}|g")"

echo "$0 $wfargs"; echo
parseArgs ${wfargs}

echo; echo "CREATING GENERAL SLURM HEADER"
getBatchScriptHeader pvhost > slurm_directives.sh
chmod +x slurm_directives.sh
cat slurm_directives.sh

echo; echo "PREPARING KILL SCRIPT TO CLEAN JOB"
sed -i "s|__controller__|${controller}|g" kill.sh
sed -i "s|__job_number__|${job_number}|g" kill.sh

sshcmd="ssh -o StrictHostKeyChecking=no ${controller}"

echo; echo "CHECKING OPENFOAM JOB DIRECTORY"
jobdir_exists=$(${sshcmd} "[ -d '${jobdir}' ] && echo 'true' || echo 'false'")

if ! [[ "${jobdir_exists}" == "true" ]]; then
    echo "ERROR: Could find OpenFOAM job directory <${jobdir}> on remote host <${controller}>"
    echo "       Try: ${sshcmd} ls ${jobdir}"
    exit 1
fi

echo; echo "LOOKING FOR OPENFOAM RESULTS"
ssh_find_cmd="${sshcmd} find ${jobdir} -maxdepth 2 -name case.foam"
cases_foam=$(${ssh_find_cmd})
if [ -z "${cases_foam}" ]; then
    echo "ERROR: No OpenFOAM results found in directory <${jobdir}> on remote host <${controller}>"
    echo "       Try command <${ssh_find_cmd}>"
    echo "       Exiting workflow"
    exit 1
fi
echo "Found the following OpenFOAM results:"
echo ${cases_foam}

echo; echo "CREATING SLURM WRAPPERS"
for case_foam in ${cases_foam}; do
    echo "  OpenFOAM results: ${case_foam}"
    case_dir=$(dirname ${case_foam} | sed "s|${jobdir}||g")
    # Case directory in user container
    mkdir -p ${PWD}/${case_dir}
    sbatch_sh=${PWD}/${case_dir}/sbatch.sh
    chdir=${jobdir}/${case_dir}
    # Create submit script
    cp slurm_directives.sh ${sbatch_sh}
    echo "#SBATCH -o ${chdir}/pw-${job_number}.out" >> ${sbatch_sh}
    echo "#SBATCH -e ${chdir}/pw-${job_number}.out" >> ${sbatch_sh}
    echo "#SBATCH --chdir=${chdir}" >> ${sbatch_sh}
    echo "cd ${chdir}"              >> ${sbatch_sh}
    if [[ "${pooltype}" == "slurmshv2" ]]; then
        echo "bash ${poolworkdir}/pw/.pw/remote.sh" >> ${sbatch_sh}
    fi
    echo "export DISPLAY=:0" >> ${sbatch_sh}
    echo "${load_paraview}" | sed "s|___| |g" | tr ';' '\n' >> ${sbatch_sh}
    echo "pvpython ${pvpython_script} ${case_foam}"  >> ${sbatch_sh}
    if [[ ${use_dex} == "True" ]]; then
        rsync_cmd="rsync -avzq -e \"ssh -J ${internalIp}\" --include='*.csv' --include='*.json' --include='*.png' --exclude='*'  ./ usercontainer:${PWD}/${case_dir}"
        echo ${rync_cmd} >>  ${sbatch_sh}
    fi
    cat ${sbatch_sh}
    scp ${sbatch_sh} ${controller}:${jobdir}/${case_dir}
done


echo; echo "LAUNCHING JOBS"
for case_foam in ${cases_foam}; do
    echo "  OpenFOAM results: ${case_foam}"
    case_dir=$(dirname ${case_foam} | sed "s|${jobdir}||g")
    remote_sbatch_sh=${jobdir}/${case_dir}/sbatch.sh
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
        exit 0
    fi

    for sj in ${submitted_jobs}; do
        slurm_job=$(cat ${sj})
        sj_status=$($sshcmd squeue -j ${slurm_job} | tail -n+2 | awk '{print $5}')
        if [ -z "${sj_status}" ]; then
            mv ${sj} ${sj}.completed
            sj_status=$($sshcmd sacct -j ${slurm_job}  --format=state | tail -n1 | tr -d ' ')
            case_dir=$(dirname ${sj} | sed "s|${PWD}/||g")
            scp ${controller}: ${controller}:${jobdir}/${case_dir}/pw-${job_number}.out ${case_dir}
        fi
        echo "  Slurm job ${slurm_job} status is ${sj_status}"
        if [[ "${sj_status}" == "FAILED" ]]; then
            FAILED=true
            FAILED_JOBS="${slurm_job}, ${FAILED_JOBS}"
        fi
    done
    sleep 60
done