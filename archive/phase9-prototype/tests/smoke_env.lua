local function configureEnv(env)
    local path = os.tmpname()
    os.remove(path)
    -- The parent fake-engine harness may use this test-only plugin metadata
    -- override when constructing the module environment.
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
