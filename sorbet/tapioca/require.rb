# typed: true
# frozen_string_literal: true

# Add your extra requires here (`bin/tapioca require` can be used to bootstrap this list)

require "money-rails/active_record/monetizable"
require "rails/all"
require "rails/generators"
require "rails/generators/app_base"
require "tapioca/dsl/compilers"
require "tapioca/dsl/helpers/active_record_constants_helper"
require "zeitwerk"
