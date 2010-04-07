require File.expand_path('../../../spec_helper', __FILE__)

describe "bundle install --flex" do
  it "installs the gems as expected" do
    flex_install_gemfile <<-G
      source "file://#{gem_repo1}"
      gem 'rack'
    G

    should_be_installed "rack 1.0.0"
    should_be_locked
  end

  it "does awesome" do
    pending
    build_repo2

    flex_install_gemfile <<-G
      source "file://#{gem_repo2}"
      gem 'rack'
    G

    update_repo2

    flex_install_gemfile <<-G
      source "file://#{gem_repo2}"
      gem 'rack'
      gem 'activesupport', '2.3.5'
    G

    should_be_installed "rack 1.0.0", 'activesupport 2.3.5'
    should_be_locked
  end
end