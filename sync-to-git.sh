#!/bin/bash

# Initialize git if not already initialized
git rev-parse --is-inside-work-tree 2>/dev/null
if [ $? -ne 0 ]; then
  git init
fi

# Add all files
git add .

# Commit changes
git commit -m "Sync project configuration and deployment files" || echo "Nothing to commit."

# Set remote if not set
git remote get-url origin 2>/dev/null
if [ $? -ne 0 ]; then
  git remote add origin https://github.com/wmwm/discord-bot.git
fi

# Pull remote changes first to avoid push rejection
git pull origin master --rebase

# Push to master branch (create 'master' if it doesn't exist, otherwise push current branch)
branch=$(git branch --show-current)
if [ "$branch" != "master" ]; then
  git branch -M master
fi
git push -u origin master
