# encoding: utf-8
#
# Copyright 2013 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.

require "test_helper"

class Api::V2::NodesControllerTest < MiniTest::Rails::ActionController::TestCase
  fixtures :all

  def setup
    login_user(User.find(users(:admin)), @org)

    @request.env['HTTP_ACCEPT'] = 'application/json'
    @read_perm = UserPermission.new(:read, :organizations, nil, nil)
    @edit_perm = UserPermission.new(:manage_nodes, :organizations, nil, nil)

  end

  test 'test index should be successful' do
    get :index
    assert_response :success
  end

  test 'test index should authorize correctly' do
    assert_protected_action(:index, [@read_perm, @edit_perm], [NO_PERMISSION]) do
      get :index
    end
  end

end