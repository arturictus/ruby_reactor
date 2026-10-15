# frozen_string_literal: true

# Shadows the bundled activerecord gem when this directory is first on the
# load path, so a spec can boot an app that has no ActiveRecord installed.
raise LoadError, "cannot load such file -- active_record"
