local function configureEnv(env)
    local path = os.tmpname()
    os.remove(path)
    -- The real loader supplies the module configuration directory. Give the
    -- smoke harness an isolated equivalent so boot exercises the same path.
    env.__plugin = {
        guid = "adamantRunPlanner-Plan_Executor",
        config_mod_folder_path = path,
    }
    return env
end

return {
    expectedPackId = "run-planner",
    expectedModuleId = "Plan_Executor",
    configureEnv = configureEnv,
}
