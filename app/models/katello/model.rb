#
# Copyright 2014 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.

# Adding this for the foreman_hooks plugin
require "active_model/forbidden_attributes_protection"

module Katello
  class Model < ActiveRecord::Base
    include ActiveModel::ForbiddenAttributesProtection
    self.abstract_class = true

    def destroy!
      unless destroy
        fail self.errors.full_messages.join('; ')
      end
    end
  end
end
