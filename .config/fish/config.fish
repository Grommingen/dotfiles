set -gx PATH /opt/homebrew/bin $HOME/Library/Python/3.9/bin $PATH
#Denne if status greia, pass på å ikke putte noe inn der enda.
if status is-interactive
    # Commands to run in interactive sessions can go here

end
starship init fish | source
# direnv stuff
# activates direnv
direnv hook fish | source
# sets direnv mode (this is the default mode)
set -g direnv_fish_mode eval_on_arrow
set -gx EDITOR vim
# source functions
#source /home/bjohoi/.config/fish/functions/__fish_complete_directories_homemade_tf.fish
#source /home/bjohoi/.config/fish/functions/__fish_complete_directories_homemade_puppet.fish
#source /home/bjohoi/.config/fish/functions/__fish_complete_directories_homemade_workpass.fish
#source /home/bjohoi/.config/fish/functions/tfjump.fish
#source /home/bjohoi/.config/fish/functions/puppetjump.fish
## source completions
#source /home/bjohoi/.config/fish/completions/tfj_complete.fish
#source /home/bjohoi/.config/fish/completions/ppj_complete.fish
#source /home/bjohoi/.config/fish/completions/workpasscompletion.fish
# PATHS
# set configs: https://mattermost.redpill-linpro.com/rl/pl/m89q6769ifgnmdqp8m55jabi5c
# not working yet alias åpnestack='mkdir -p /run/user/1000/openstack/ ;gpg -d ~/.config/openstack/clouds.yaml.gpg > /run/user/1000/openstack/clouds.yaml'

# Aliases
if command -sq /usr/bin/bat
  alias cat="bat --plain"
end
alias bat="bat --plain"
