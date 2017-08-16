Rails.application.routes.draw do
  # Enablement for the REST API

  namespace :api, :path => "api(/:version)", :version => Api::VERSION_REGEX, :defaults => {:format => "json"} do
    root :to => "api#index", :as => :entrypoint
    match "/", :to => "api#options", :via => :options

    # Redirect of /tasks subcollections to /request_tasks
    [:automation_requests, :provision_requests, :requests, :service_requests].each do |collection_name|
      get "/#{collection_name}/:c_id/tasks", :to => redirect { |path_params, _req| "/api/#{collection_name}/#{path_params[:c_id]}/request_tasks" }
      get "/#{collection_name}/:c_id/tasks/:s_id", :to => redirect { |path_params, _req| "/api/#{collection_name}/#{path_params[:c_id]}/request_tasks/#{path_params[:s_id]}" }
    end

    Api::ApiConfig.collections.each do |collection_name, collection|
      # OPTIONS action for each collection
      match collection_name.to_s, :controller => collection_name, :action => :options, :via => :options

      scope collection_name, :controller => collection_name do
        collection.verbs.each do |verb|
          root :action => Api::VERBS_ACTIONS_MAP[verb], :via => verb if collection.options.include?(:primary)

          next unless collection.options.include?(:collection)

          if collection.options.include?(:arbitrary_resource_path)
            case verb
            when :get
              root :action => :index
              get "/*c_suffix", :action => :show
            else
              match "(/*c_suffix)", :action => Api::VERBS_ACTIONS_MAP[verb], :via => verb
            end
          else
            case verb
            when :get
              root :action => :index
              get "/:c_id", :action => :show
            when :put
              put "/:c_id", :action => :update
            when :patch
              patch "/:c_id", :action => :update
            when :delete
              delete "/:c_id", :action => :destroy
            when :post
              post "(/:c_id)", :action => :update
            end
          end
        end

        Array(collection.subcollections).each do |subcollection_name|
          Api::ApiConfig.collections[subcollection_name].verbs.each do |verb|
            case verb
            when :get
              get "/:c_id/#{subcollection_name}", :action => :index
              get "/:c_id/#{subcollection_name}/:s_id", :action => :show
            when :put
              put "/:c_id/#{subcollection_name}/:s_id", :action => :update
            when :patch
              patch "/:c_id/#{subcollection_name}/:s_id", :action => :update
            when :delete
              delete "/:c_id/#{subcollection_name}/:s_id", :action => :destroy
            when :post
              post "/:c_id/#{subcollection_name}(/:s_id)", :action => :update
            end
          end
        end
      end
    end
  end
end
